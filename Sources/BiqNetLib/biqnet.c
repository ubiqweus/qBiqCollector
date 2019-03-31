#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

int receive_from(int fd, int seconds, void * received, int size)
{
    if (fd < 1 || seconds < 1 || !received) return -1;
    fd_set rds_base, eds_base;
    FD_ZERO(&rds_base);
    FD_ZERO(&eds_base);
    FD_SET(fd, &rds_base);
    FD_SET(fd, &eds_base);
    struct timeval tv;
    memset(&tv, 0, sizeof(tv));
    tv.tv_sec = seconds;
    int wait = select(fd + 1, &rds_base, NULL, &eds_base, &tv);
    if (wait == 0) return 0;
    if (wait < 0) return wait;
    if (FD_ISSET(fd, &eds_base)) return -2;
    if (!FD_ISSET(fd, &rds_base)) return -3;
    return recv(fd, received, size, 0);
}