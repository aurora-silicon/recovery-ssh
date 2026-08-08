#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

static int write_all(int fd, const unsigned char *buf, size_t len)
{
    while (len != 0) {
        ssize_t written = write(fd, buf, len);
        if (written < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        buf += written;
        len -= (size_t)written;
    }
    return 0;
}

int main(void)
{
    int master = -1;
    int status = 0;
    pid_t child = forkpty(&master, NULL, NULL, NULL);
    if (child < 0) {
        perror("forkpty");
        return 1;
    }
    if (child == 0) {
        execl("/bin/sh", "sh", "-i", (char *)NULL);
        perror("execl");
        _exit(127);
    }

    signal(SIGPIPE, SIG_IGN);
    unsigned char buf[4096];
    int input_open = 1;

    for (;;) {
        struct pollfd fds[2] = {
            {.fd = STDIN_FILENO, .events = input_open ? POLLIN : 0},
            {.fd = master, .events = POLLIN},
        };
        int rc;
        do {
            rc = poll(fds, 2, -1);
        } while (rc < 0 && errno == EINTR);
        if (rc < 0) {
            perror("poll");
            break;
        }

        if (input_open && (fds[0].revents & (POLLIN | POLLHUP))) {
            ssize_t count = read(STDIN_FILENO, buf, sizeof(buf));
            if (count > 0) {
                if (write_all(master, buf, (size_t)count) < 0)
                    break;
            } else {
                const unsigned char end_of_input = 0x04;
                if (write_all(master, &end_of_input, 1) < 0)
                    break;
                input_open = 0;
            }
        }

        if (fds[1].revents & (POLLIN | POLLHUP | POLLERR)) {
            ssize_t count = read(master, buf, sizeof(buf));
            if (count > 0) {
                if (write_all(STDOUT_FILENO, buf, (size_t)count) < 0)
                    break;
            } else {
                break;
            }
        }
    }

    close(master);
    kill(child, SIGHUP);
    while (waitpid(child, &status, 0) < 0 && errno == EINTR)
        ;

    if (WIFEXITED(status))
        return WEXITSTATUS(status);
    return 0;
}
