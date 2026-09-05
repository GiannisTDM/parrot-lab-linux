#include "CLinuxBridge.h"
#ifdef __linux__
#include <gtk/gtk.h>
#include <gst/app/gstappsrc.h>
#include <gst/app/gstappsink.h>
#include <gst/video/video.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

static GtkWidget *window, *picture, *horizon, *status_label, *telemetry_label, *log_label;
static GtkWidget *host_entry, *connect_button, *video_button, *record_button;
static GMainLoop *main_loop;
static GstElement *pipeline, *source, *sink;
static GdkTexture *last_texture;
static PLAction action_callback;
static PLTick tick_callback;
static void *callback_context;
static double roll_angle, pitch_angle;
static uint64_t decoded_frames;
static char video_error[512];
static gboolean demo_video;
static char *capture_path;
static GdkFrameClock *capture_clock;
static gulong capture_handler;
static int capture_status;

int pl_desktop_available(void) { return 1; }
const char *pl_video_error(void) { return video_error; }
uint64_t pl_video_frames(void) { return decoded_frames; }

void pl_video_stop(void) {
    if (pipeline) {
        gst_element_set_state(pipeline, GST_STATE_NULL);
        if (source) gst_object_unref(source);
        if (sink) gst_object_unref(sink);
        gst_object_unref(pipeline);
    }
    pipeline = source = sink = NULL;
    if (picture) gtk_picture_set_paintable(GTK_PICTURE(picture), NULL);
    g_clear_object(&last_texture);
}

int pl_video_start(int demo) {
    pl_video_stop();
    video_error[0] = 0;
    decoded_frames = 0;
    demo_video = demo;
    GError *error = NULL;
    const char *description = demo
        ? "videotestsrc is-live=true pattern=ball ! video/x-raw,width=960,height=540,framerate=30/1 ! videoconvert ! video/x-raw,format=BGRA ! appsink name=frames max-buffers=1 drop=true sync=false"
        : "appsrc name=encoded is-live=true format=time block=false max-bytes=4194304 caps=video/x-h264,stream-format=byte-stream,alignment=au ! h264parse ! avdec_h264 max-threads=2 ! videoconvert ! video/x-raw,format=BGRA ! appsink name=frames max-buffers=1 drop=true sync=false";
    pipeline = gst_parse_launch(description, &error);
    if (error || !pipeline) {
        snprintf(video_error, sizeof(video_error), "%s", error ? error->message : "Could not build video pipeline");
        g_clear_error(&error); pl_video_stop(); return 0;
    }
    source = demo ? NULL : gst_bin_get_by_name(GST_BIN(pipeline), "encoded");
    sink = gst_bin_get_by_name(GST_BIN(pipeline), "frames");
    if (gst_element_set_state(pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
        snprintf(video_error, sizeof(video_error), "Video pipeline could not start");
        pl_video_stop(); return 0;
    }
    return 1;
}

int pl_video_push(const uint8_t *data, size_t size, uint64_t pts_ns) {
    if (!source || demo_video || video_error[0]) return 0;
    guint64 queued = 0;
    g_object_get(source, "current-level-bytes", &queued, NULL);
    if (queued + size > 4194304) {
        snprintf(video_error, sizeof(video_error), "Decoder cannot keep up; video stopped at the 4 MiB queue limit");
        return 0;
    }
    GstBuffer *buffer = gst_buffer_new_allocate(NULL, size, NULL);
    gst_buffer_fill(buffer, 0, data, size);
    GST_BUFFER_PTS(buffer) = pts_ns;
    GstFlowReturn result = gst_app_src_push_buffer(GST_APP_SRC(source), buffer);
    if (result != GST_FLOW_OK) {
        snprintf(video_error, sizeof(video_error), "Decoder rejected frame (%d)", result);
        return 0;
    }
    return 1;
}

static void poll_video(void) {
    if (!pipeline) return;
    GstBus *bus = gst_element_get_bus(pipeline);
    GstMessage *message;
    while ((message = gst_bus_pop_filtered(bus, GST_MESSAGE_ERROR | GST_MESSAGE_EOS))) {
        if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR) {
            GError *error = NULL; gchar *debug = NULL;
            gst_message_parse_error(message, &error, &debug);
            snprintf(video_error, sizeof(video_error), "%s", error->message);
            g_error_free(error); g_free(debug);
        } else snprintf(video_error, sizeof(video_error), "Video stream ended");
        gst_message_unref(message);
    }
    gst_object_unref(bus);
    GstSample *sample = gst_app_sink_try_pull_sample(GST_APP_SINK(sink), 0);
    if (!sample) return;
    GstVideoInfo info;
    GstVideoFrame frame;
    if (gst_video_info_from_caps(&info, gst_sample_get_caps(sample)) &&
        gst_video_frame_map(&frame, &info, gst_sample_get_buffer(sample), GST_MAP_READ)) {
        int width = GST_VIDEO_INFO_WIDTH(&info), height = GST_VIDEO_INFO_HEIGHT(&info);
        int stride = GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0);
        if (stride >= width * 4 && width > 0 && height > 0) {
            GBytes *bytes = g_bytes_new(GST_VIDEO_FRAME_PLANE_DATA(&frame, 0), (size_t)stride * height);
            GdkTexture *texture = gdk_memory_texture_new(width, height, GDK_MEMORY_B8G8R8A8, bytes, stride);
            g_bytes_unref(bytes);
            if (picture) gtk_picture_set_paintable(GTK_PICTURE(picture), GDK_PAINTABLE(texture));
            g_clear_object(&last_texture); last_texture = texture;
            decoded_frames++;
        }
        gst_video_frame_unmap(&frame);
    }
    gst_sample_unref(sample);
}

int pl_video_snapshot(const char *path) {
    return last_texture && gdk_texture_save_to_png(last_texture, path);
}

static int capture_current_window(const char *path) {
    if (!window) return 0;
    int w = gtk_widget_get_width(window), h = gtk_widget_get_height(window);
    GtkSnapshot *snapshot = gtk_snapshot_new();
    GdkRGBA background = {0.063, 0.098, 0.118, 1};
    graphene_rect_t bounds = GRAPHENE_RECT_INIT(0, 0, w, h);
    gtk_snapshot_append_color(snapshot, &background, &bounds);
    gtk_widget_snapshot_child(window, gtk_window_get_child(GTK_WINDOW(window)), snapshot);
    GskRenderNode *node = gtk_snapshot_free_to_node(snapshot);
    if (!node) return 0;
    GskRenderer *renderer = gtk_native_get_renderer(GTK_NATIVE(window));
    GdkTexture *texture = gsk_renderer_render_texture(renderer, node, NULL);
    gsk_render_node_unref(node);
    int result = texture && gdk_texture_save_to_png(texture, path);
    g_clear_object(&texture);
    return result;
}

static void capture_after_paint(GdkFrameClock *clock, gpointer unused) {
    (void)unused;
    capture_status = capture_current_window(capture_path) ? 2 : -1;
    g_signal_handler_disconnect(clock, capture_handler); capture_handler = 0;
    g_clear_pointer(&capture_path, g_free);
    g_clear_object(&capture_clock);
}
int pl_desktop_capture(const char *path) {
    if (!window || capture_handler) return 0;
    GdkFrameClock *clock = gtk_widget_get_frame_clock(window);
    if (!clock) return 0;
    capture_clock = g_object_ref(clock);
    capture_path = g_strdup(path); capture_status = 1;
    capture_handler = g_signal_connect(clock, "after-paint", G_CALLBACK(capture_after_paint), NULL);
    gtk_widget_queue_draw(window);
    return 1;
}
int pl_desktop_capture_status(void) { return capture_status; }

static void draw_horizon(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    (void)area; (void)data;
    cairo_translate(cr, width / 2.0, height / 2.0);
    cairo_set_source_rgba(cr, 0.2, 0.95, 0.82, 0.95);
    cairo_set_line_width(cr, 2);
    cairo_move_to(cr, -35, 0); cairo_line_to(cr, -10, 0);
    cairo_move_to(cr, 10, 0); cairo_line_to(cr, 35, 0);
    cairo_move_to(cr, 0, -8); cairo_line_to(cr, 0, 8); cairo_stroke(cr);
    if (!isfinite(roll_angle) || !isfinite(pitch_angle)) return;
    cairo_rotate(cr, -roll_angle);
    cairo_translate(cr, 0, pitch_angle * height * 0.7);
    cairo_set_source_rgba(cr, 1, 1, 1, 0.75);
    cairo_move_to(cr, -130, 0); cairo_line_to(cr, -45, 0);
    cairo_move_to(cr, 45, 0); cairo_line_to(cr, 130, 0); cairo_stroke(cr);
}

static void clicked(GtkButton *button, gpointer value) {
    (void)button;
    action_callback(callback_context, GPOINTER_TO_INT(value), gtk_editable_get_text(GTK_EDITABLE(host_entry)));
}
static GtkWidget *button(const char *label, int action) {
    GtkWidget *widget = gtk_button_new_with_label(label);
    g_signal_connect(widget, "clicked", G_CALLBACK(clicked), GINT_TO_POINTER(action));
    return widget;
}
static GtkWidget *label(const char *text) {
    GtkWidget *widget = gtk_label_new(text);
    gtk_label_set_xalign(GTK_LABEL(widget), 0);
    gtk_label_set_wrap(GTK_LABEL(widget), TRUE);
    return widget;
}
static gboolean tick(gpointer unused) {
    (void)unused; tick_callback(callback_context); poll_video(); return G_SOURCE_CONTINUE;
}
static gboolean close_window(GtkWindow *widget, gpointer unused) {
    (void)widget; (void)unused; g_main_loop_quit(main_loop); return TRUE;
}
static gboolean timed_quit(gpointer unused) {
    (void)unused; g_main_loop_quit(main_loop); return G_SOURCE_REMOVE;
}
void pl_desktop_update(const char *status, const char *telemetry, const char *log,
                       double roll, double pitch, int connected, int video, int recording) {
    gtk_label_set_text(GTK_LABEL(status_label), status);
    gtk_label_set_text(GTK_LABEL(telemetry_label), telemetry);
    gtk_label_set_text(GTK_LABEL(log_label), log);
    gtk_button_set_label(GTK_BUTTON(connect_button), connected ? "Disconnect" : "Connect");
    gtk_widget_set_sensitive(host_entry, !connected);
    gtk_button_set_label(GTK_BUTTON(video_button), video ? "Stop video" : "Start video");
    gtk_button_set_label(GTK_BUTTON(record_button), recording ? "Stop archive" : "Archive H.264");
    roll_angle = roll; pitch_angle = pitch;
    gtk_widget_queue_draw(horizon);
}
int pl_desktop_run(void *context, PLAction action, PLTick callback, const char *host, double quit_after) {
    if (!gtk_init_check()) { fprintf(stderr, "No graphical display. Use --headless or run inside an Ubuntu desktop session.\n"); return 2; }
    gst_init(NULL, NULL);
    callback_context = context; action_callback = action; tick_callback = callback;
    main_loop = g_main_loop_new(NULL, FALSE);
    GtkCssProvider *css = gtk_css_provider_new();
    gtk_css_provider_load_from_string(css,
        "window {background:#10191e;color:#e1eff1;} button {padding:9px 14px;}"
        ".title {font-size:26px;font-weight:bold;color:#51dcc4;}"
        ".muted {color:#9caeb6;} .panel {background:#1a282f;border-radius:12px;padding:18px;}"
        ".telemetry {font-family:monospace;font-size:16px;} .console {font-family:monospace;font-size:12px;}"
        "entry {min-width:145px;} .video {background:#060b0e;border-radius:12px;}");
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(css);
    window = gtk_window_new();
    gtk_window_set_title(GTK_WINDOW(window), "Parrot Lab · Linux");
    gtk_window_set_default_size(GTK_WINDOW(window), 1180, 780);
    g_signal_connect(window, "close-request", G_CALLBACK(close_window), NULL);
    GtkWidget *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 14);
    gtk_widget_set_margin_start(root, 20); gtk_widget_set_margin_end(root, 20);
    gtk_widget_set_margin_top(root, 20); gtk_widget_set_margin_bottom(root, 20);
    gtk_window_set_child(GTK_WINDOW(window), root);
    GtkWidget *title = label("PARROT LAB  /  LINUX"); gtk_widget_add_css_class(title, "title");
    gtk_box_append(GTK_BOX(root), title);
    GtkWidget *subtitle = label("Bebop 2 & SkyController 2   ·   Telemetry and video preview");
    gtk_widget_add_css_class(subtitle, "muted"); gtk_box_append(GTK_BOX(root), subtitle);
    GtkWidget *toolbar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_box_append(GTK_BOX(root), toolbar);
    host_entry = gtk_entry_new(); gtk_editable_set_text(GTK_EDITABLE(host_entry), host);
    gtk_box_append(GTK_BOX(toolbar), host_entry);
    connect_button = button("Connect", 1); video_button = button("Start video", 2);
    record_button = button("Archive H.264", 4);
    gtk_box_append(GTK_BOX(toolbar), connect_button); gtk_box_append(GTK_BOX(toolbar), video_button);
    gtk_box_append(GTK_BOX(toolbar), button("Demo", 3));
    gtk_box_append(GTK_BOX(toolbar), record_button); gtk_box_append(GTK_BOX(toolbar), button("Save PNG", 5));
    status_label = label("Ready · enter the controller IPv4 address or select Demo");
    gtk_box_append(GTK_BOX(root), status_label);
    GtkWidget *content = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 14);
    gtk_widget_set_vexpand(content, TRUE); gtk_box_append(GTK_BOX(root), content);
    GtkWidget *overlay = gtk_overlay_new(); gtk_widget_add_css_class(overlay, "video");
    gtk_widget_set_hexpand(overlay, TRUE); gtk_widget_set_vexpand(overlay, TRUE);
    gtk_widget_set_size_request(overlay, 540, 300);
    picture = gtk_picture_new(); gtk_picture_set_can_shrink(GTK_PICTURE(picture), TRUE);
    gtk_picture_set_content_fit(GTK_PICTURE(picture), GTK_CONTENT_FIT_CONTAIN);
    gtk_overlay_set_child(GTK_OVERLAY(overlay), picture);
    horizon = gtk_drawing_area_new(); gtk_widget_set_can_target(horizon, FALSE);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(horizon), draw_horizon, NULL, NULL);
    gtk_overlay_add_overlay(GTK_OVERLAY(overlay), horizon);
    gtk_box_append(GTK_BOX(content), overlay);
    telemetry_label = label("Awaiting telemetry");
    gtk_widget_add_css_class(telemetry_label, "panel"); gtk_widget_add_css_class(telemetry_label, "telemetry");
    gtk_widget_set_size_request(telemetry_label, 265, -1);
    gtk_widget_set_valign(telemetry_label, GTK_ALIGN_FILL);
    gtk_label_set_yalign(GTK_LABEL(telemetry_label), 0);
    gtk_box_append(GTK_BOX(content), telemetry_label);
    log_label = label(""); gtk_widget_add_css_class(log_label, "panel"); gtk_widget_add_css_class(log_label, "console");
    gtk_label_set_ellipsize(GTK_LABEL(log_label), PANGO_ELLIPSIZE_END);
    gtk_label_set_lines(GTK_LABEL(log_label), 5); gtk_widget_set_size_request(log_label, -1, 96);
    gtk_box_append(GTK_BOX(root), log_label);
    gtk_window_present(GTK_WINDOW(window));
    guint timer = g_timeout_add(16, tick, NULL);
    guint quit_timer = quit_after > 0 ? g_timeout_add((guint)(quit_after * 1000), timed_quit, NULL) : 0;
    g_main_loop_run(main_loop);
    g_source_remove(timer);
    if (quit_timer && g_main_context_find_source_by_id(NULL, quit_timer)) g_source_remove(quit_timer);
    if (capture_handler) {
        g_signal_handler_disconnect(capture_clock, capture_handler); capture_handler = 0;
        capture_status = -1;
    }
    g_clear_pointer(&capture_path, g_free); g_clear_object(&capture_clock);
    pl_video_stop(); gtk_window_destroy(GTK_WINDOW(window));
    g_main_loop_unref(main_loop);
    window = picture = horizon = NULL;
    return 0;
}
#else
int pl_desktop_available(void) { return 0; }
int pl_desktop_run(void *c, PLAction a, PLTick t, const char *h, double q) { return 2; }
void pl_desktop_update(const char *s, const char *t, const char *l, double r, double p, int c, int v, int a) {}
int pl_video_start(int demo) { return 0; }
void pl_video_stop(void) {}
int pl_video_push(const uint8_t *d, size_t s, uint64_t p) { return 0; }
const char *pl_video_error(void) { return "Desktop video requires Linux"; }
uint64_t pl_video_frames(void) { return 0; }
int pl_video_snapshot(const char *path) { return 0; }
int pl_desktop_capture(const char *path) { return 0; }
int pl_desktop_capture_status(void) { return -1; }
#endif
