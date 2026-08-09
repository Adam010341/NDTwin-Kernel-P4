/*
 * Establishes that glibc's inet_ntoa returns a thread-local buffer, so the race an audit
 * attributed to utils::ipToString could not have occurred on this platform.
 *
 * [Co-developed with claude code -- Adam]
 *
 * Not part of the CMake build: it is a claim-checker, not a test of this project's code, and it
 * would fail to compile the point it makes on a libc that does not offer the guarantee. The
 * comment at the top of tests/test_IpToString.cpp used to say "a small C program confirms it"
 * while that program existed only in /tmp -- making the one load-bearing claim in that comment
 * the one thing a reader could not reproduce.
 *
 * Build and run:
 *   cc -pthread -o /tmp/ntoa_tls tests/manual/inet_ntoa_buffer_is_thread_local.c && /tmp/ntoa_tls
 *
 * Expected on glibc >= 2.32: the two pointers differ, and each thread reads back its own address.
 * If they are equal, inet_ntoa shares one buffer process-wide on this libc, the audit's race is
 * real there, and utils::ipToString must keep using inet_ntop (it does).
 */

#include <arpa/inet.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

static const char* mainBuffer;
static const char* threadBuffer;
static char mainValue[INET_ADDRSTRLEN];
static char threadValue[INET_ADDRSTRLEN];

static void*
inOtherThread(void* unused)
{
    (void)unused;
    struct in_addr addr;
    addr.s_addr = inet_addr("10.20.30.40");
    threadBuffer = inet_ntoa(addr);
    snprintf(threadValue, sizeof(threadValue), "%s", threadBuffer);
    return NULL;
}

int
main(void)
{
    struct in_addr addr;
    addr.s_addr = inet_addr("1.2.3.4");
    mainBuffer = inet_ntoa(addr);
    snprintf(mainValue, sizeof(mainValue), "%s", mainBuffer);

    pthread_t other;
    if (pthread_create(&other, NULL, inOtherThread, NULL) != 0)
    {
        fprintf(stderr, "pthread_create failed\n");
        return 2;
    }
    pthread_join(other, NULL);

    printf("main thread buffer:  %p -> %s\n", (const void*)mainBuffer, mainValue);
    printf("other thread buffer: %p -> %s\n", (const void*)threadBuffer, threadValue);

    const int distinct = (mainBuffer != threadBuffer);
    const int mainStillCorrect = (strcmp(mainValue, "1.2.3.4") == 0);
    const int otherCorrect = (strcmp(threadValue, "10.20.30.40") == 0);

    /* Read the main thread's buffer again *after* the other thread wrote: if the buffer were
     * shared, this would now show the other thread's address. */
    const int mainBufferUnclobbered = (strcmp(mainBuffer, "1.2.3.4") == 0);

    printf("\nbuffers are distinct:            %s\n", distinct ? "yes" : "NO");
    printf("main's buffer still reads 1.2.3.4: %s\n", mainBufferUnclobbered ? "yes" : "NO");

    if (distinct && mainStillCorrect && otherCorrect && mainBufferUnclobbered)
    {
        printf("\nCONCLUSION: inet_ntoa's buffer is thread-local on this libc.\n");
        return 0;
    }

    printf("\nCONCLUSION: inet_ntoa shares a buffer across threads on this libc --\n"
           "the race described in the audit is real here.\n");
    return 1;
}
