#include "AZSSMC.h"

#include <cstdio>
#include <cstdlib>
#include <cerrno>
#include <cstddef>
#include <cstring>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <string>

static bool writeAll(int fd, const char *data, size_t length) {
    while (length > 0) {
        const ssize_t written = write(fd, data, length);
        if (written <= 0) return false;
        data += written;
        length -= static_cast<size_t>(written);
    }
    return true;
}

static bool readLine(int fd, std::string &line) {
    line.clear();
    char byte = 0;
    while (line.size() < 256) {
        const ssize_t count = read(fd, &byte, 1);
        if (count <= 0) return !line.empty();
        if (byte == '\n') return true;
        line.push_back(byte);
    }
    return false;
}

static int handleCommand(const std::string &command) {
    if (command == "ping") return 0;
    if (command == "quit") return 2;

    if (command.rfind("set-target ", 0) == 0) {
        int index = -1;
        double rpm = 0.0;
        if (std::sscanf(command.c_str(), "set-target %d %lf", &index, &rpm) == 2 && index >= 0) {
            return AZSSMCSetFanTarget(index, rpm) ? 0 : 1;
        }
        return 1;
    }

    if (command.rfind("set-auto ", 0) == 0) {
        int index = -1;
        if (std::sscanf(command.c_str(), "set-auto %d", &index) == 1 && index >= 0) {
            return AZSSMCSetFanAuto(index) ? 0 : 1;
        }
        return 1;
    }
    return 1;
}

static int runServerLoop(const char *socketPath, uid_t requestedUID, gid_t requestedGID) {
    sockaddr_un address{};
    if (!socketPath || std::strlen(socketPath) >= sizeof(address.sun_path)) return 2;

    const int server = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server < 0) return 2;

    unlink(socketPath);
    address.sun_family = AF_UNIX;
    std::strncpy(address.sun_path, socketPath, sizeof(address.sun_path) - 1);
    const socklen_t addressLength = static_cast<socklen_t>(offsetof(sockaddr_un, sun_path) + std::strlen(address.sun_path) + 1);
    if (bind(server, reinterpret_cast<sockaddr *>(&address), addressLength) != 0 ||
        chmod(socketPath, 0600) != 0 || listen(server, 4) != 0) {
        close(server);
        unlink(socketPath);
        return 2;
    }

    // The app creates a private parent directory before elevating this helper.
    // Transfer the socket ownership back to that directory's user so the
    // non-root app can connect while all other users remain blocked.
    uid_t allowedUID = requestedUID;
    gid_t allowedGID = requestedGID;
    if (allowedUID == static_cast<uid_t>(-1)) {
        std::string parent(socketPath);
        const size_t slash = parent.rfind('/');
        if (slash != std::string::npos && slash > 0) {
            parent.resize(slash);
            struct stat owner{};
            if (stat(parent.c_str(), &owner) == 0) {
                allowedUID = owner.st_uid;
                allowedGID = owner.st_gid;
            }
        }
    }
    if (allowedUID != static_cast<uid_t>(-1)) {
        if (chown(socketPath, allowedUID, allowedGID) != 0 || chmod(socketPath, 0600) != 0) {
            close(server);
            unlink(socketPath);
            return 2;
        }
    }

    for (;;) {
        const int client = accept(server, nullptr, nullptr);
        if (client < 0) {
            if (errno == EINTR) continue;
            break;
        }
        uid_t peerUID = static_cast<uid_t>(-1);
        gid_t peerGID = static_cast<gid_t>(-1);
        if (allowedUID != static_cast<uid_t>(-1) &&
            (getpeereid(client, &peerUID, &peerGID) != 0 ||
             (peerUID != allowedUID && peerUID != 0))) {
            writeAll(client, "ERR\n", 4);
            close(client);
            continue;
        }
        std::string command;
        const bool valid = readLine(client, command);
        const int result = valid ? handleCommand(command) : 1;
        const char *response = result == 1 ? "ERR\n" : "OK\n";
        writeAll(client, response, std::strlen(response));
        close(client);
        if (result == 2) break;
    }

    close(server);
    unlink(socketPath);
    return 1;
}

// The helper is launched by AppleScript with admin privileges. Daemonize
// inside the helper itself instead of relying on a shell background job;
// macOS may terminate background children of `do shell script` otherwise.
static int runServer(const char *socketPath) {
    const pid_t child = fork();
    if (child < 0) return 2;
    if (child > 0) return 0;

    (void)setsid();
    close(STDIN_FILENO);
    close(STDOUT_FILENO);
    close(STDERR_FILENO);
    const int result = runServerLoop(socketPath, static_cast<uid_t>(-1), static_cast<gid_t>(-1));
    _exit(result);
}

int main(int argc, char **argv) {
    if (argc >= 5 && std::string(argv[1]) == "--launchd-server") {
        const uid_t uid = static_cast<uid_t>(std::strtoul(argv[3], nullptr, 10));
        const gid_t gid = static_cast<gid_t>(std::strtoul(argv[4], nullptr, 10));
        return runServerLoop(argv[2], uid, gid);
    }
    if (argc >= 3 && std::string(argv[1]) == "--server") {
        return runServer(argv[2]);
    }
    if (argc >= 3 && std::string(argv[1]) == "--set-target") {
        const int index = std::atoi(argv[2]);
        const double rpm = argc >= 4 ? std::atof(argv[3]) : 0.0;
        return AZSSMCSetFanTarget(index, rpm) ? 0 : 1;
    }
    if (argc >= 3 && std::string(argv[1]) == "--set-auto") {
        return AZSSMCSetFanAuto(std::atoi(argv[2])) ? 0 : 1;
    }
    std::fprintf(stderr, "Usage: azs-smc-helper --set-target INDEX RPM | --set-auto INDEX\n");
    return 2;
}
