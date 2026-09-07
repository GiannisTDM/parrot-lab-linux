#include "CLinuxBridge.h"
#ifdef __linux__
#include <gtk/gtk.h>
#include <glib-unix.h>
#include <signal.h>
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
static GtkWidget *mode_button, *ground_row, *arm_button, *speed_scale, *subtitle_label;
static int desktop_mode, held_keys, held_mouse;

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
    demo_video = demo == 1;
    GError *error = NULL;
    const char *description = demo == 1
        ? "videotestsrc is-live=true pattern=ball ! video/x-raw,width=960,height=540,framerate=30/1 ! videoconvert ! video/x-raw,format=BGRA ! appsink name=frames max-buffers=1 drop=true sync=false"
        : demo == 2
        ? "appsrc name=encoded is-live=true format=time block=false max-bytes=4194304 caps=image/jpeg ! jpegparse ! jpegdec ! videoconvert ! video/x-raw,format=BGRA ! appsink name=frames max-buffers=1 drop=true sync=false"
        : "appsrc name=encoded is-live=true format=time block=false max-bytes=4194304 caps=video/x-h264,stream-format=byte-stream,alignment=au ! h264parse ! avdec_h264 max-threads=2 ! videoconvert ! video/x-raw,format=BGRA ! appsink name=frames max-buffers=1 drop=true sync=false";
    pipeline = gst_parse_launch(description, &error);
    if (error || !pipeline) {
        snprintf(video_error, sizeof(video_error), "%s", error ? error->message : "Could not build video pipeline");
        g_clear_error(&error); pl_video_stop(); return 0;
    }
    source = demo == 1 ? NULL : gst_bin_get_by_name(GST_BIN(pipeline), "encoded");
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
    // Use the actual CSS background, including the current theme transition.
    gtk_snapshot_render_background(snapshot, gtk_widget_get_style_context(window), 0, 0, w, h);
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
    if (GPOINTER_TO_INT(value) == 10 || GPOINTER_TO_INT(value) == 11) {
        held_keys = held_mouse = 0;
        gtk_widget_grab_focus(arm_button);
    }
    action_callback(callback_context, GPOINTER_TO_INT(value), gtk_editable_get_text(GTK_EDITABLE(host_entry)));
}
static void ground_stop(void) {
    held_keys = held_mouse = 0;
    if (action_callback) action_callback(callback_context, 11, "");
}
static int direction(guint key) {
    switch (gdk_keyval_to_lower(key)) {
    case GDK_KEY_w: case GDK_KEY_Up: return 1;
    case GDK_KEY_s: case GDK_KEY_Down: return 2;
    case GDK_KEY_a: case GDK_KEY_Left: return 4;
    case GDK_KEY_d: case GDK_KEY_Right: return 8;
    default: return 0;
    }
}
static gboolean key_pressed(GtkEventControllerKey *controller, guint key, guint code, GdkModifierType state, gpointer unused) {
    (void)controller; (void)code; (void)unused;
    if (!desktop_mode) return FALSE;
    if (key == GDK_KEY_Escape || key == GDK_KEY_space) { ground_stop(); return TRUE; }
    if (key == GDK_KEY_F6) {
        // Do not let keyboard auto-repeat repeatedly re-arm the controller.
        return TRUE; // arm once on release below
    }
    GtkWidget *focus = gtk_root_get_focus(GTK_ROOT(window));
    if ((focus && GTK_IS_EDITABLE(focus)) || (state & (GDK_CONTROL_MASK | GDK_ALT_MASK | GDK_SUPER_MASK))) return FALSE;
    int bit = direction(key);
    held_keys |= bit;
    return bit != 0;
}
static void key_released(GtkEventControllerKey *controller, guint key, guint code, GdkModifierType state, gpointer unused) {
    (void)controller; (void)code; (void)state; (void)unused;
    held_keys &= ~direction(key);
    if (desktop_mode && key == GDK_KEY_F6) {
        held_keys = held_mouse = 0;
        gtk_widget_grab_focus(arm_button); action_callback(callback_context, 10, "");
    }
}
static void active_changed(GObject *object, GParamSpec *spec, gpointer unused) {
    (void)object; (void)spec; (void)unused;
    if (!gtk_window_is_active(GTK_WINDOW(window))) ground_stop();
}
static gboolean focus_event(GtkEventControllerLegacy *controller, GdkEvent *event, gpointer unused) {
    (void)controller; (void)unused;
    if (gdk_event_get_event_type(event) == GDK_FOCUS_CHANGE && !gdk_focus_event_get_in(event)) ground_stop();
    return FALSE;
}
static void drive_pressed(GtkGestureClick *gesture, int count, double x, double y, gpointer bit) {
    (void)gesture; (void)count; (void)x; (void)y;
    gtk_gesture_set_state(GTK_GESTURE(gesture), GTK_EVENT_SEQUENCE_CLAIMED);
    held_mouse |= GPOINTER_TO_INT(bit);
}
static void drive_released(GtkGestureClick *gesture, int count, double x, double y, gpointer bit) {
    (void)gesture; (void)count; (void)x; (void)y;
    held_mouse &= ~GPOINTER_TO_INT(bit);
}
static void drive_cancel(GtkGesture *gesture, GdkEventSequence *sequence, gpointer bit) {
    (void)gesture; (void)sequence;
    held_mouse &= ~GPOINTER_TO_INT(bit);
}
static GtkWidget *drive_button(const char *text, int bit) {
    GtkWidget *widget = gtk_button_new_with_label(text);
    GtkGesture *gesture = gtk_gesture_click_new();
    gtk_event_controller_set_propagation_phase(GTK_EVENT_CONTROLLER(gesture), GTK_PHASE_CAPTURE);
    g_signal_connect(gesture, "pressed", G_CALLBACK(drive_pressed), GINT_TO_POINTER(bit));
    g_signal_connect(gesture, "released", G_CALLBACK(drive_released), GINT_TO_POINTER(bit));
    g_signal_connect(gesture, "cancel", G_CALLBACK(drive_cancel), GINT_TO_POINTER(bit));
    gtk_widget_add_controller(widget, GTK_EVENT_CONTROLLER(gesture));
    return widget;
}
static void speed_changed(GtkRange *range, gpointer unused) {
    (void)unused; char value[8]; snprintf(value, sizeof(value), "%d", (int)gtk_range_get_value(range));
    action_callback(callback_context, 12, value);
}
void pl_desktop_mode(int mode, const char *host) {
    desktop_mode = mode; ground_stop();
    if (mode) gtk_widget_add_css_class(window, "ground");
    else gtk_widget_remove_css_class(window, "ground");
    gtk_editable_set_text(GTK_EDITABLE(host_entry), host);
    gtk_button_set_label(GTK_BUTTON(mode_button), mode == 1 ? "Mode: Sumo Wi-Fi" : mode == 2 ? "Mode: Sumo SC2" : "Mode: Air");
    gtk_label_set_text(GTK_LABEL(subtitle_label), mode ? "Jumping Sumo · ground driving and video · release to stop" : "Bebop 2 & SkyController 2 · Telemetry and video preview");
    gtk_widget_set_visible(ground_row, mode != 0); gtk_widget_set_visible(horizon, mode == 0);
}
void pl_ground_update(int armed, int ready, int limit) {
    gtk_button_set_label(GTK_BUTTON(arm_button), armed ? "Disarm drive" : "Arm drive (F6)");
    gtk_widget_set_sensitive(arm_button, ready);
    if (!armed) held_keys = held_mouse = 0;
    if ((int)gtk_range_get_value(GTK_RANGE(speed_scale)) != limit) gtk_range_set_value(GTK_RANGE(speed_scale), limit);
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
    (void)unused;
    if (desktop_mode) {
        GtkWidget *focus = gtk_root_get_focus(GTK_ROOT(window));
        if (focus && (GTK_IS_EDITABLE(focus) || GTK_IS_RANGE(focus))) ground_stop();
        char mask[8]; snprintf(mask, sizeof(mask), "%d", held_keys | held_mouse);
        action_callback(callback_context, 30, mask);
    }
    tick_callback(callback_context); poll_video(); return G_SOURCE_CONTINUE;
}
static gboolean close_window(GtkWindow *widget, gpointer unused) {
    (void)widget; (void)unused; ground_stop(); g_main_loop_quit(main_loop); return TRUE;
}
static gboolean timed_quit(gpointer unused) {
    (void)unused; ground_stop(); g_main_loop_quit(main_loop); return G_SOURCE_REMOVE;
}
void pl_desktop_update(const char *status, const char *telemetry, const char *log,
                       double roll, double pitch, int connected, int video, int recording) {
    gtk_label_set_text(GTK_LABEL(status_label), status);
    gtk_label_set_text(GTK_LABEL(telemetry_label), telemetry);
    gtk_label_set_text(GTK_LABEL(log_label), log);
    gtk_button_set_label(GTK_BUTTON(connect_button), connected ? "Disconnect" : "Connect");
    gtk_widget_set_sensitive(host_entry, !connected);
    gtk_button_set_label(GTK_BUTTON(video_button), video ? "Stop video" : "Start video");
    gtk_button_set_label(GTK_BUTTON(record_button), recording ? "Stop archive" : desktop_mode == 1 ? "Archive MJPEG" : "Archive H.264");
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
        // Match LabVisualStyle's air/ground palette and 380 ms workspace fade.
        // Only interface chrome changes; decoded video pixels stay untouched.
        "window {background:#0b1116;color:#e1eff1;}"
        "window,button,entry,.title,.muted,.panel,scale highlight,scale slider {"
        "transition:background-color 380ms ease-in-out,color 380ms ease-in-out,border-color 380ms ease-in-out;}"
        "button {padding:9px 14px;background-image:none;background-color:#181f27;color:#e1eff1;border:1px solid #33404d;}"
        "button:hover {background-color:#253748;} button:active {background-color:#304b63;}"
        "button:disabled {color:#78828a;} button:focus-visible,entry:focus-within {outline:2px solid #59c2ff;outline-offset:2px;}"
        ".title {font-size:26px;font-weight:bold;color:#59c2ff;}"
        ".muted {color:#9caeb6;} .panel {background:#12161c;border-radius:12px;padding:18px;}"
        ".telemetry {font-family:monospace;font-size:16px;} .console {font-family:monospace;font-size:12px;}"
        "entry {min-width:145px;background-color:#181f27;color:#e1eff1;border-color:#33404d;}"
        "scale highlight,scale slider {background-image:none;background-color:#59c2ff;border-color:#59c2ff;}"
        "window.ground {background-color:#180f09;color:#f1e8df;}"
        ".ground .title {color:#f0a363;} .ground .muted {color:#b4a496;}"
        ".ground .panel {background-color:#1c1815;}"
        ".ground button,.ground entry {background-color:#261f1a;color:#f1e8df;border-color:#514033;}"
        ".ground button:hover {background-color:#3b2c20;} .ground button:active {background-color:#543c29;}"
        ".ground button:disabled {color:#958476;}"
        ".ground button:focus-visible,.ground entry:focus-within {outline-color:#f0a363;}"
        ".ground scale highlight,.ground scale slider {background-color:#f0a363;border-color:#f0a363;}"
        ".video {background:#060b0e;border-radius:12px;}");
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(css);
    window = gtk_window_new();
    gtk_window_set_title(GTK_WINDOW(window), "Parrot Lab · Linux");
    gtk_window_set_default_size(GTK_WINDOW(window), 1180, 780);
    g_signal_connect(window, "close-request", G_CALLBACK(close_window), NULL);
    g_signal_connect(window, "notify::is-active", G_CALLBACK(active_changed), NULL);
    GtkEventController *keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
    g_signal_connect(keys, "key-pressed", G_CALLBACK(key_pressed), NULL);
    g_signal_connect(keys, "key-released", G_CALLBACK(key_released), NULL);
    gtk_widget_add_controller(window, keys);
    GtkEventController *focus_events = gtk_event_controller_legacy_new();
    gtk_event_controller_set_propagation_phase(focus_events, GTK_PHASE_CAPTURE);
    g_signal_connect(focus_events, "event", G_CALLBACK(focus_event), NULL);
    gtk_widget_add_controller(window, focus_events);
    GtkWidget *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 14);
    gtk_widget_set_margin_start(root, 20); gtk_widget_set_margin_end(root, 20);
    gtk_widget_set_margin_top(root, 20); gtk_widget_set_margin_bottom(root, 20);
    gtk_window_set_child(GTK_WINDOW(window), root);
    GtkWidget *title = label("PARROT LAB  /  LINUX"); gtk_widget_add_css_class(title, "title");
    gtk_box_append(GTK_BOX(root), title);
    GtkWidget *subtitle = label("Bebop 2 & SkyController 2   ·   Telemetry and video preview");
    subtitle_label = subtitle;
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
    mode_button = button("Mode: Air", 6); gtk_box_append(GTK_BOX(toolbar), mode_button);
    ground_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_box_append(GTK_BOX(root), ground_row);
    arm_button = button("Arm drive (F6)", 10); gtk_box_append(GTK_BOX(ground_row), arm_button);
    gtk_box_append(GTK_BOX(ground_row), button("STOP", 11));
    gtk_box_append(GTK_BOX(ground_row), drive_button("Forward", 1));
    gtk_box_append(GTK_BOX(ground_row), drive_button("Back", 2));
    gtk_box_append(GTK_BOX(ground_row), drive_button("Left", 4));
    gtk_box_append(GTK_BOX(ground_row), drive_button("Right", 8));
    GtkWidget *speed_label = label("Limit %"); gtk_label_set_wrap(GTK_LABEL(speed_label), FALSE);
    gtk_box_append(GTK_BOX(ground_row), speed_label);
    speed_scale = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, 0, 100, 5);
    gtk_range_set_value(GTK_RANGE(speed_scale), 30); gtk_scale_set_draw_value(GTK_SCALE(speed_scale), TRUE);
    gtk_widget_set_size_request(speed_scale, 180, -1);
    g_signal_connect(speed_scale, "value-changed", G_CALLBACK(speed_changed), NULL);
    gtk_box_append(GTK_BOX(ground_row), speed_scale);
    gtk_widget_set_visible(ground_row, FALSE);
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
    guint interrupt = g_unix_signal_add(SIGINT, timed_quit, NULL);
    guint terminate = g_unix_signal_add(SIGTERM, timed_quit, NULL);
    guint quit_timer = quit_after > 0 ? g_timeout_add((guint)(quit_after * 1000), timed_quit, NULL) : 0;
    g_main_loop_run(main_loop);
    g_source_remove(timer);
    if (g_main_context_find_source_by_id(NULL, interrupt)) g_source_remove(interrupt);
    if (g_main_context_find_source_by_id(NULL, terminate)) g_source_remove(terminate);
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
void pl_desktop_mode(int mode, const char *host) {}
void pl_ground_update(int armed, int ready, int limit) {}
#endif
