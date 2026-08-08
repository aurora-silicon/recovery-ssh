#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static volatile sig_atomic_t running = 1;
static int server_socket = -1;

static void stop_server(int signal_number)
{
    (void)signal_number;
    running = 0;
    if (server_socket >= 0) {
        close(server_socket);
        server_socket = -1;
    }
}

static int write_all(int fd, const void *data, size_t length)
{
    const unsigned char *cursor = data;
    while (length != 0) {
        ssize_t written = write(fd, cursor, length);
        if (written < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        cursor += written;
        length -= (size_t)written;
    }
    return 0;
}

static void send_error(int client, int status, const char *reason)
{
    char response[512];
    int length = snprintf(response, sizeof(response),
        "HTTP/1.1 %d %s\r\n"
        "Connection: close\r\n"
        "Content-Type: text/plain\r\n"
        "Content-Length: %zu\r\n\r\n%s\n",
        status, reason, strlen(reason) + 1, reason);
    if (length > 0)
        (void)write_all(client, response, (size_t)length);
}

static void serve_file(int client, const char *file_path)
{
    struct stat info;
    if (stat(file_path, &info) < 0 || !S_ISREG(info.st_mode)) {
        send_error(client, 404, "Not Found");
        return;
    }

    int file = open(file_path, O_RDONLY);
    if (file < 0) {
        send_error(client, 500, "Internal Server Error");
        return;
    }

    char header[512];
    int header_length = snprintf(header, sizeof(header),
        "HTTP/1.1 200 OK\r\n"
        "Connection: close\r\n"
        "Cache-Control: no-store\r\n"
        "Content-Type: application/octet-stream\r\n"
        "Content-Length: %lld\r\n\r\n",
        (long long)info.st_size);
    if (header_length <= 0 ||
        write_all(client, header, (size_t)header_length) < 0) {
        close(file);
        return;
    }

    unsigned char buffer[16384];
    for (;;) {
        ssize_t count = read(file, buffer, sizeof(buffer));
        if (count == 0)
            break;
        if (count < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (write_all(client, buffer, (size_t)count) < 0)
            break;
    }
    close(file);
}

static void serve_bootstrap(int client, const char *installer_url)
{
    char body[2048];
    int body_length = snprintf(body, sizeof(body),
        "#!/bin/sh\n"
        "set -e\n"
        "installer=\"${TMPDIR:-/tmp}/recovery-ssh-install\"\n"
        "/usr/bin/curl -fL '%s' -o \"$installer\"\n"
        "exec /bin/sh \"$installer\"\n",
        installer_url);
    if (body_length <= 0 || (size_t)body_length >= sizeof(body)) {
        send_error(client, 500, "Internal Server Error");
        return;
    }

    char header[512];
    int header_length = snprintf(header, sizeof(header),
        "HTTP/1.1 200 OK\r\n"
        "Connection: close\r\n"
        "Cache-Control: no-store\r\n"
        "Content-Type: text/x-shellscript\r\n"
        "Content-Length: %d\r\n\r\n",
        body_length);
    if (header_length <= 0 ||
        write_all(client, header, (size_t)header_length) < 0)
        return;
    (void)write_all(client, body, (size_t)body_length);
}

int main(int argc, char **argv)
{
    if (argc != 5 && argc != 6) {
        fprintf(stderr,
            "usage: %s BIND_ADDRESS PORT URL_PATH FILE [SHORT_INSTALLER_URL]\n",
            argv[0]);
        return 2;
    }

    char *end = NULL;
    long port = strtol(argv[2], &end, 10);
    if (end == argv[2] || *end != '\0' || port < 1 || port > 65535) {
        fprintf(stderr, "invalid port: %s\n", argv[2]);
        return 2;
    }
    if (argv[3][0] != '/') {
        fprintf(stderr, "URL path must begin with /\n");
        return 2;
    }

    signal(SIGINT, stop_server);
    signal(SIGTERM, stop_server);
    signal(SIGPIPE, SIG_IGN);

    server_socket = socket(AF_INET, SOCK_STREAM, 0);
    if (server_socket < 0) {
        perror("socket");
        return 1;
    }
    int reuse = 1;
    (void)setsockopt(server_socket, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons((unsigned short)port);
    if (strcmp(argv[1], "0.0.0.0") == 0) {
        address.sin_addr.s_addr = htonl(INADDR_ANY);
    } else if (inet_pton(AF_INET, argv[1], &address.sin_addr) != 1) {
        fprintf(stderr, "invalid IPv4 bind address: %s\n", argv[1]);
        close(server_socket);
        server_socket = -1;
        return 2;
    }

    if (bind(server_socket, (struct sockaddr *)&address, sizeof(address)) < 0) {
        perror("bind");
        close(server_socket);
        server_socket = -1;
        return 1;
    }
    if (listen(server_socket, 8) < 0) {
        perror("listen");
        close(server_socket);
        server_socket = -1;
        return 1;
    }

    fprintf(stderr, "Serving %s at http://%s:%ld%s\n",
        argv[4], argv[1], port, argv[3]);

    while (running) {
        int client = accept(server_socket, NULL, NULL);
        if (client < 0) {
            if (!running)
                break;
            if (errno == EINTR)
                continue;
            perror("accept");
            break;
        }

        char request[4096];
        ssize_t count = read(client, request, sizeof(request) - 1);
        if (count <= 0) {
            close(client);
            continue;
        }
        request[count] = '\0';

        char method[16];
        char path[1024];
        if (sscanf(request, "%15s %1023s", method, path) != 2) {
            send_error(client, 400, "Bad Request");
        } else if (strcmp(method, "GET") != 0) {
            send_error(client, 405, "Method Not Allowed");
        } else if (strcmp(path, "/r") == 0 && argc == 6) {
            fprintf(stderr, "Recovery bootstrap requested\n");
            serve_bootstrap(client, argv[5]);
        } else if (strcmp(path, argv[3]) != 0) {
            send_error(client, 404, "Not Found");
        } else {
            fprintf(stderr, "Recovery installer requested\n");
            serve_file(client, argv[4]);
        }
        close(client);
    }

    if (server_socket >= 0)
        close(server_socket);
    return 0;
}
