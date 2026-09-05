#include "CLinuxBridge.h"
#include <sys/socket.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <errno.h>
#include <time.h>

static int64_t milliseconds(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static int ready(int fd, short events, int64_t deadline) {
    struct pollfd p = {.fd = fd, .events = events};
    for (;;) {
        int64_t left = deadline - milliseconds();
        if (left < 0) left = 0;
        int r = poll(&p, 1, (int)left);
        if (r < 0 && errno == EINTR) continue;
        if (r == 0) { errno = ETIMEDOUT; return 0; }
        return r;
    }
}
static int address(const char *host, uint16_t port, struct sockaddr_in *addr) {
    *addr = (struct sockaddr_in){.sin_family = AF_INET, .sin_port = htons(port)};
    if (inet_pton(AF_INET, host, &addr->sin_addr) != 1) { errno = EINVAL; return -1; }
    return 0;
}
int pl_ipv4_valid(const char *host) { struct in_addr a; return inet_pton(AF_INET, host, &a) == 1; }
static int make_socket(int type) {
    int fd = socket(AF_INET, type, 0);
    if (fd < 0) return -1;
    if (fcntl(fd, F_SETFL, O_NONBLOCK) < 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) {
        int e = errno; close(fd); errno = e; return -1;
    }
#ifdef SO_NOSIGPIPE
    int yes = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
    return fd;
}
int pl_tcp_open(const char *host, uint16_t port, int timeout_ms) {
    struct sockaddr_in a;
    if (address(host, port, &a) < 0) return -1;
    int fd = make_socket(SOCK_STREAM);
    if (fd < 0) return -1;
    int result = connect(fd, (struct sockaddr *)&a, sizeof(a));
    if (result < 0 && errno == EINPROGRESS) {
        result = ready(fd, POLLOUT, milliseconds() + timeout_ms);
        if (result > 0) {
            int error = 0; socklen_t length = sizeof(error);
            result = getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length);
            if (result == 0 && error) { errno = error; result = -1; }
        } else result = -1;
    }
    if (result < 0) { int e = errno; close(fd); errno = e; return -1; }
    return fd;
}
int pl_udp_open(uint16_t port) {
    int fd = make_socket(SOCK_DGRAM);
    if (fd < 0) return -1;
    int bytes = 4 * 1024 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bytes, sizeof(bytes));
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = INADDR_ANY};
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) < 0) {
        int e = errno; close(fd); errno = e; return -1;
    }
    return fd;
}
uint16_t pl_local_port(int fd) {
    struct sockaddr_in a; socklen_t len = sizeof(a);
    return getsockname(fd, (struct sockaddr *)&a, &len) == 0 ? ntohs(a.sin_port) : 0;
}
int pl_socket_peer(int fd, const char *host, uint16_t port) {
    struct sockaddr_in a;
    if (address(host, port, &a) < 0) return -1;
    return connect(fd, (struct sockaddr *)&a, sizeof(a));
}
int pl_receive(int fd, void *buffer, size_t capacity, int timeout_ms) {
    int r = ready(fd, POLLIN, milliseconds() + timeout_ms);
    if (r == 0) return -2;
    if (r < 0) return -1;
    ssize_t n = recv(fd, buffer, capacity, 0);
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) return -2;
    return (int)n;
}
int pl_send(int fd, const void *buffer, size_t size, int timeout_ms) {
    int64_t deadline = milliseconds() + timeout_ms;
    size_t sent = 0;
    while (sent < size) {
        if (ready(fd, POLLOUT, deadline) <= 0) return -1;
#ifdef MSG_NOSIGNAL
        int flags = MSG_NOSIGNAL;
#else
        int flags = 0;
#endif
        ssize_t n = send(fd, (const char *)buffer + sent, size - sent, flags);
        if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (n <= 0) return -1;
        sent += n;
    }
    return (int)sent;
}
void pl_close(int fd) { if (fd >= 0) close(fd); }
