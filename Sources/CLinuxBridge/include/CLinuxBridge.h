#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// All networking calls are bounded and operate on IPv4 literals.
int pl_tcp_open(const char *host, uint16_t port, int timeout_ms);
int pl_udp_open(uint16_t port);
uint16_t pl_local_port(int fd);
int pl_socket_peer(int fd, const char *host, uint16_t port);
int pl_receive(int fd, void *buffer, size_t capacity, int timeout_ms);
int pl_send(int fd, const void *buffer, size_t size, int timeout_ms);
void pl_close(int fd);
int pl_ipv4_valid(const char *host);

typedef void (*PLAction)(void *context, int action, const char *host);
typedef void (*PLTick)(void *context);
// UI and video API must be called on the Qt GUI thread. Payloads are copied.
int pl_desktop_run(void *context, PLAction action, PLTick tick, const char *host, double quit_after);
void pl_desktop_update(const char *status, const char *telemetry, const char *log,
                       double roll, double pitch, int connected, int video, int recording);
int pl_video_start(int demo);
void pl_video_stop(void);
int pl_video_push(const uint8_t *data, size_t size, uint64_t pts_ns);
const char *pl_video_error(void);
uint64_t pl_video_frames(void);
int pl_video_snapshot(const char *path);
int pl_desktop_available(void);
int pl_desktop_capture(const char *path);
int pl_desktop_capture_status(void); // 0 idle, 1 pending, 2 saved, -1 failed
void pl_desktop_mode(int mode, const char *host);
void pl_ground_update(int armed, int ready, int limit);

#ifdef __cplusplus
}
#endif
