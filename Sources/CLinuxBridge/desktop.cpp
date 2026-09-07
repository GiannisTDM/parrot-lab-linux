#include "CLinuxBridge.h"
#ifdef __linux__
#include <QApplication>
#include <QCloseEvent>
#include <QHBoxLayout>
#include <QImage>
#include <QKeyEvent>
#include <QLabel>
#include <QLineEdit>
#include <QMouseEvent>
#include <QPainter>
#include <QPushButton>
#include <QSignalBlocker>
#include <QShortcut>
#include <QSlider>
#include <QStyle>
#include <QTimer>
#include <QVariantAnimation>
#include <QVBoxLayout>
#include <gst/app/gstappsrc.h>
#include <gst/app/gstappsink.h>
#include <gst/video/video.h>
#include <cmath>
#include <cstdio>
#include <csignal>

static GstElement *pipeline, *source, *sink;
static QImage last_image;
static PLAction action_callback;
static PLTick tick_callback;
static void *callback_context;
static double roll_angle, pitch_angle;
static uint64_t decoded_frames;
static char video_error[512];
static gboolean demo_video;
static int capture_status, desktop_mode, held_keys, held_mouse;
static volatile sig_atomic_t quit_signal;
static void repaint_video();
static void ground_stop() {
    held_keys = held_mouse = 0;
    if (action_callback) action_callback(callback_context, 11, "");
}
// No Qt or Swift calls from an asynchronous signal handler.
static void handle_signal(int signal) { quit_signal = signal; }

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
    last_image = QImage();
    repaint_video();
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
    while ((message = gst_bus_pop_filtered(bus, static_cast<GstMessageType>(GST_MESSAGE_ERROR | GST_MESSAGE_EOS)))) {
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
            // Copy before unmapping: Qt must never reference a recycled GstBuffer.
            last_image = QImage(static_cast<const uchar *>(GST_VIDEO_FRAME_PLANE_DATA(&frame, 0)),
                                width, height, stride, QImage::Format_ARGB32).copy();
            repaint_video();
            decoded_frames++;
        }
        gst_video_frame_unmap(&frame);
    }
    gst_sample_unref(sample);
}


class VideoView final : public QWidget {
public:
    explicit VideoView(QWidget *parent = nullptr) : QWidget(parent) {
        setMinimumSize(540, 300);
        setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
        setAccessibleName("Video preview");
    }
protected:
    void paintEvent(QPaintEvent *) override {
        QPainter p(this);
        p.setRenderHint(QPainter::Antialiasing);
        p.setBrush(QColor("#060b0e")); p.setPen(Qt::NoPen);
        p.drawRoundedRect(rect(), 12, 12);
        if (!last_image.isNull()) {
            QSize size = last_image.size().scaled(this->size(), Qt::KeepAspectRatio);
            QRect target(QPoint((width() - size.width()) / 2, (height() - size.height()) / 2), size);
            p.setRenderHint(QPainter::SmoothPixmapTransform);
            p.drawImage(target, last_image);
        }
        if (desktop_mode) return;
        p.translate(width() / 2.0, height() / 2.0);
        p.setPen(QPen(QColor("#59c2ff"), 2));
        p.drawLine(-35, 0, -10, 0); p.drawLine(10, 0, 35, 0); p.drawLine(0, -8, 0, 8);
        if (!std::isfinite(roll_angle) || !std::isfinite(pitch_angle)) return;
        p.rotate(-roll_angle * 180.0 / 3.141592653589793);
        p.translate(0, pitch_angle * height() * 0.7);
        p.setPen(QPen(QColor(255, 255, 255, 191), 2));
        p.drawLine(-130, 0, -45, 0); p.drawLine(45, 0, 130, 0);
    }
};

class DriveButton final : public QPushButton {
    int bit;
public:
    DriveButton(const char *text, int direction) : QPushButton(text), bit(direction) {
        setAutoRepeat(false);
        setAccessibleName(QString("Hold to drive %1").arg(text));
    }
protected:
    void mousePressEvent(QMouseEvent *event) override {
        if (event->button() == Qt::LeftButton) held_mouse |= bit;
        QPushButton::mousePressEvent(event);
    }
    void mouseMoveEvent(QMouseEvent *event) override {
        if (!rect().contains(event->position().toPoint())) held_mouse &= ~bit;
        QPushButton::mouseMoveEvent(event);
    }
    void mouseReleaseEvent(QMouseEvent *event) override {
        held_mouse &= ~bit; // including a release outside the button
        QPushButton::mouseReleaseEvent(event);
    }
    bool event(QEvent *event) override {
        if (event->type() == QEvent::UngrabMouse || event->type() == QEvent::Hide)
            held_mouse &= ~bit;
        return QPushButton::event(event);
    }
};

class Desktop final : public QWidget {
public:
    VideoView *picture;
    QLabel *status, *telemetry, *log, *subtitle, *speedValue;
    QLineEdit *host;
    QPushButton *connectButton, *videoButton, *recordButton, *modeButton, *armButton;
    QWidget *groundRow;
    QSlider *speed;
    QVariantAnimation theme;
    double warmth = 0;
    explicit Desktop(const char *address) {
        setObjectName("desktop");
        setWindowTitle("Parrot Lab · Linux");
        resize(1180, 800);
        auto *root = new QVBoxLayout(this);
        root->setContentsMargins(20, 20, 20, 20); root->setSpacing(14);
        auto *title = new QLabel("PARROT LAB  /  LINUX");
        title->setObjectName("title"); root->addWidget(title);
        subtitle = new QLabel("Bebop 2 & SkyController 2 · Telemetry and video preview");
        subtitle->setObjectName("subtitle"); root->addWidget(subtitle);
        auto *toolbar = new QHBoxLayout; toolbar->setSpacing(8);
        host = new QLineEdit(address); host->setFixedWidth(168);
        host->setAccessibleName("Controller IPv4 address"); toolbar->addWidget(host);
        connectButton = button("Connect", 1); toolbar->addWidget(connectButton);
        videoButton = button("Start video", 2); toolbar->addWidget(videoButton);
        toolbar->addWidget(button("Demo", 3));
        recordButton = button("Archive H.264", 4); toolbar->addWidget(recordButton);
        toolbar->addWidget(button("Save PNG", 5));
        modeButton = button("Mode: Air", 6); toolbar->addWidget(modeButton);
        modeButton->setAccessibleName("Connection mode");
        // A stable shortcut also permits display-scale-independent integration tests.
        // Keep the shortcut separate: changing a button's text resets its mnemonic.
        auto *modeShortcut = new QShortcut(QKeySequence(Qt::Key_F7), this);
        QObject::connect(modeShortcut, &QShortcut::activated, this, [this] { modeButton->click(); });
        modeButton->setToolTip("Cycle Air / Sumo Wi-Fi / Sumo SC2 (F7)");
        toolbar->addStretch(); root->addLayout(toolbar);
        groundRow = new QWidget;
        auto *ground = new QHBoxLayout(groundRow); ground->setContentsMargins(0, 0, 0, 0); ground->setSpacing(8);
        armButton = button("Arm drive (F6)", 10); ground->addWidget(armButton);
        ground->addWidget(button("STOP", 11));
        for (auto entry : {std::pair<const char *, int>{"Forward", 1}, {"Back", 2}, {"Left", 4}, {"Right", 8}})
            ground->addWidget(new DriveButton(entry.first, entry.second));
        ground->addWidget(new QLabel("Limit %"));
        speed = new QSlider(Qt::Horizontal); speed->setRange(0, 100);
        speed->setSingleStep(5); speed->setValue(30); speed->setFixedWidth(155);
        speed->setAccessibleName("Ground speed limit percent");
        ground->addWidget(speed); speedValue = new QLabel("30"); speedValue->setMinimumWidth(30);
        ground->addWidget(speedValue); ground->addStretch();
        QObject::connect(speed, &QSlider::valueChanged, this, [this](int value) {
            ground_stop();
            speedValue->setText(QString::number(value));
            auto text = QByteArray::number(value); action_callback(callback_context, 12, text.constData());
        });
        root->addWidget(groundRow); groundRow->hide();
        status = new QLabel("Ready · enter the controller IPv4 address or select Demo");
        status->setWordWrap(true); root->addWidget(status);
        auto *content = new QHBoxLayout; content->setSpacing(14);
        picture = new VideoView; content->addWidget(picture, 1);
        telemetry = new QLabel("Awaiting telemetry");
        telemetry->setTextFormat(Qt::PlainText); telemetry->setObjectName("telemetry");
        telemetry->setAlignment(Qt::AlignLeft | Qt::AlignTop);
        telemetry->setMinimumWidth(265); telemetry->setSizePolicy(QSizePolicy::Preferred, QSizePolicy::Expanding);
        content->addWidget(telemetry); root->addLayout(content, 1);
        log = new QLabel; log->setTextFormat(Qt::PlainText); log->setObjectName("console");
        log->setWordWrap(true); log->setFixedHeight(104);
        log->setSizePolicy(QSizePolicy::Ignored, QSizePolicy::Fixed);
        root->addWidget(log);
        QObject::connect(&theme, &QVariantAnimation::valueChanged, this, [this](const QVariant &value) {
            warmth = value.toDouble(); applyTheme();
        });
        theme.setDuration(380); theme.setEasingCurve(QEasingCurve::InOutCubic);
        applyTheme();
        qApp->installEventFilter(this);
        QObject::connect(qApp, &QApplication::focusChanged, this, [](QWidget *, QWidget *focus) {
            if (desktop_mode && (qobject_cast<QLineEdit *>(focus) || qobject_cast<QSlider *>(focus))) ground_stop();
        });
    }
    QPushButton *button(const char *text, int action) {
        auto *result = new QPushButton(text);
        QObject::connect(result, &QPushButton::clicked, this, [this, action] {
            if (action == 10 || action == 11) { held_keys = held_mouse = 0; armButton->setFocus(); }
            auto address = host->text().toUtf8(); action_callback(callback_context, action, address.constData());
        });
        return result;
    }
    void switchTheme(bool ground) {
        theme.stop();
        // Start from the displayed colour so rapid toggling never jumps to an old endpoint.
        theme.setStartValue(warmth); theme.setEndValue(ground ? 1.0 : 0.0);
        // Qt's menu/combo effect flags are not a cross-platform reduced-motion
        // preference. Provide an explicit app-level override for this animation.
        if (!isVisible() || qEnvironmentVariableIntValue("PARROTLAB_REDUCE_MOTION") != 0) {
            warmth = ground ? 1 : 0; applyTheme();
        } else theme.start();
    }
    void applyTheme() {
        auto color = [this](const char *air, const char *ground) {
            QColor a(air), b(ground);
            return QColor(qRound(a.red() + (b.red() - a.red()) * warmth),
                          qRound(a.green() + (b.green() - a.green()) * warmth),
                          qRound(a.blue() + (b.blue() - a.blue()) * warmth)).name();
        };
        const auto bg = color("#0b1116", "#180f09"), text = color("#e1eff1", "#f1e8df");
        const auto raised = color("#181f27", "#261f1a"), border = color("#33404d", "#514033");
        const auto accent = color("#59c2ff", "#f0a363"), panel = color("#12161c", "#1c1815");
        const auto muted = color("#9caeb6", "#b4a496"), hover = color("#253748", "#3b2c20");
        const auto pressed = color("#304b63", "#543c29");
        setStyleSheet(QString(
            "QWidget#desktop {background:%1;} QWidget {color:%2;font-size:14px;}"
            "QLabel {background:transparent;} QLabel#title {font-size:26px;font-weight:bold;color:%5;}"
            "QLabel#subtitle {color:%7;}"
            "QPushButton,QLineEdit {background:%3;border:1px solid %4;border-radius:5px;padding:10px 14px;}"
            "QPushButton:hover {background:%8;} QPushButton:pressed {background:%9;}"
            "QPushButton:focus,QLineEdit:focus {border-color:%5;}"
            "QPushButton:disabled {color:%7;} QLineEdit {selection-background-color:%5;selection-color:#101010;}"
            "QLabel#telemetry,QLabel#console {background:%6;border-radius:12px;padding:18px;font-family:monospace;}"
            "QLabel#telemetry {font-size:16px;} QLabel#console {font-size:12px;}"
            "QSlider::groove:horizontal {height:4px;background:%4;border-radius:2px;}"
            "QSlider::sub-page:horizontal {background:%5;}"
            "QSlider::handle:horizontal {background:%5;border:1px solid %5;width:18px;margin:-7px 0;border-radius:9px;}"
            "QSlider:focus {border:1px solid %5;border-radius:4px;}"
        ).arg(bg, text, raised, border, accent, panel, muted, hover, pressed));
    }
    static int direction(int key) {
        switch (key) {
        case Qt::Key_W: case Qt::Key_Up: return 1;
        case Qt::Key_S: case Qt::Key_Down: return 2;
        case Qt::Key_A: case Qt::Key_Left: return 4;
        case Qt::Key_D: case Qt::Key_Right: return 8;
        default: return 0;
        }
    }
protected:
    void closeEvent(QCloseEvent *event) override { ground_stop(); event->accept(); }
    bool eventFilter(QObject *object, QEvent *event) override {
        if ((object == this && event->type() == QEvent::WindowDeactivate) ||
            event->type() == QEvent::ApplicationDeactivate) ground_stop();
        if (!desktop_mode) return false;
        if (event->type() != QEvent::KeyPress && event->type() != QEvent::KeyRelease) return false;
        auto *key = static_cast<QKeyEvent *>(event);
        const bool down = event->type() == QEvent::KeyPress;
        if (key->key() == Qt::Key_Escape || key->key() == Qt::Key_Space) {
            if (down) ground_stop(); return true;
        }
        if (key->key() == Qt::Key_F6) {
            if (!down && !key->isAutoRepeat()) {
                held_keys = held_mouse = 0; armButton->setFocus(); action_callback(callback_context, 10, "");
            }
            return true;
        }
        int bit = direction(key->key());
        if (!bit) return false;
        auto *focus = QApplication::focusWidget();
        if (qobject_cast<QLineEdit *>(focus) || qobject_cast<QSlider *>(focus)) {
            held_keys &= ~bit; return false;
        }
        if (key->isAutoRepeat()) return true;
        if (!down) { held_keys &= ~bit; return true; }
        if (key->modifiers() & (Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier)) return false;
        held_keys |= bit; return true;
    }
};

static Desktop *window;
static void repaint_video() { if (window) window->picture->update(); }
int pl_video_snapshot(const char *path) {
    return !last_image.isNull() && last_image.save(QString::fromUtf8(path), "PNG");
}
int pl_desktop_capture(const char *path) {
    if (!window || capture_status == 1) return 0;
    capture_status = 1;
    const QString destination = QString::fromUtf8(path);
    QTimer::singleShot(0, window, [destination] {
        capture_status = window->grab().save(destination, "PNG") ? 2 : -1;
    });
    return 1;
}
int pl_desktop_capture_status(void) { return capture_status; }
void pl_desktop_mode(int mode, const char *host) {
    desktop_mode = mode; ground_stop();
    window->host->setText(QString::fromUtf8(host));
    window->modeButton->setText(mode == 1 ? "Mode: Sumo Wi-Fi" : mode == 2 ? "Mode: Sumo SC2" : "Mode: Air");
    window->subtitle->setText(mode ? "Jumping Sumo · ground driving and video · release to stop"
                                  : "Bebop 2 & SkyController 2 · Telemetry and video preview");
    window->groundRow->setVisible(mode != 0);
    window->switchTheme(mode != 0); repaint_video();
}
void pl_ground_update(int armed, int ready, int limit) {
    window->armButton->setText(armed ? "Disarm drive" : "Arm drive (F6)");
    window->armButton->setEnabled(ready);
    if (!armed) held_keys = held_mouse = 0;
    QSignalBlocker blocked(window->speed);
    window->speed->setValue(limit); window->speedValue->setText(QString::number(limit));
}
void pl_desktop_update(const char *status, const char *telemetry, const char *log,
                       double roll, double pitch, int connected, int video, int recording) {
    window->status->setText(QString::fromUtf8(status));
    window->telemetry->setText(QString::fromUtf8(telemetry));
    window->log->setText(QString::fromUtf8(log));
    window->connectButton->setText(connected ? "Disconnect" : "Connect");
    window->host->setEnabled(!connected);
    window->videoButton->setText(video ? "Stop video" : "Start video");
    window->recordButton->setText(recording ? "Stop archive" : desktop_mode == 1 ? "Archive MJPEG" : "Archive H.264");
    roll_angle = roll; pitch_angle = pitch; repaint_video();
}
int pl_desktop_run(void *context, PLAction action, PLTick callback, const char *host, double quit_after) {
    if (qEnvironmentVariableIsEmpty("DISPLAY") && qEnvironmentVariableIsEmpty("WAYLAND_DISPLAY") &&
        qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM")) {
        fprintf(stderr, "No graphical display. Use --headless or run inside an Ubuntu desktop session.\n"); return 2;
    }
    int argc = 1; char name[] = "parrot-lab"; char *argv[] = {name, nullptr};
    QApplication application(argc, argv);
    QApplication::setStyle("Fusion"); // consistent, no GTK platform-theme dependency
    QApplication::setApplicationName("Parrot Lab");
    gst_init(nullptr, nullptr);
    callback_context = context; action_callback = action; tick_callback = callback;
    capture_status = 0; desktop_mode = 0; held_keys = held_mouse = 0; quit_signal = 0;
    Desktop desktop(host); window = &desktop;
    struct sigaction handler{}, previous_int{}, previous_term{};
    handler.sa_handler = handle_signal; sigemptyset(&handler.sa_mask);
    sigaction(SIGINT, &handler, &previous_int); sigaction(SIGTERM, &handler, &previous_term);
    QTimer timer;
    timer.setTimerType(Qt::PreciseTimer);
    QObject::connect(&timer, &QTimer::timeout, &desktop, [&] {
        if (quit_signal) { ground_stop(); application.quit(); return; }
        if (desktop_mode) {
            auto *focus = QApplication::focusWidget();
            if (qobject_cast<QLineEdit *>(focus) || qobject_cast<QSlider *>(focus)) ground_stop();
            auto mask = QByteArray::number(held_keys | held_mouse); action_callback(context, 30, mask.constData());
        }
        tick_callback(context); poll_video();
    });
    if (quit_after > 0) QTimer::singleShot(static_cast<int>(quit_after * 1000), &desktop, [&] {
        ground_stop(); application.quit();
    });
    desktop.show(); timer.start(16);
    const int result = application.exec();
    timer.stop(); ground_stop(); pl_video_stop();
    if (capture_status == 1) capture_status = -1;
    qApp->removeEventFilter(&desktop); window = nullptr;
    sigaction(SIGINT, &previous_int, nullptr); sigaction(SIGTERM, &previous_term, nullptr);
    return result;
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
