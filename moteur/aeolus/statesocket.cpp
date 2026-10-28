#include "aeolus/statesocket.h"
#include "aeolus/engine.h"

#if JUCE_LINUX

#include <sys/socket.h>
#include <sys/un.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>
#include <poll.h>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <cstdio>
#include <sstream>
#include <charconv>
#include <algorithm>

using namespace juce;

AEOLUS_NAMESPACE_BEGIN

// Locale-independent (snprintf would write "0,5" under a French locale).
static std::string formatFloat(float v)
{
    char buf[64];
    auto res = std::to_chars(buf, buf + sizeof(buf), v);
    return std::string(buf, res.ptr);
}

StateSocket::StateSocket()
{
    _path = resolvePath();
    _instance = std::to_string(getpid()) + "-" + std::to_string((long)std::time(nullptr));

    unlink(_path.c_str());

    _listenFd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (_listenFd < 0)
        return;

    int flags = fcntl(_listenFd, F_GETFL, 0);
    fcntl(_listenFd, F_SETFL, flags | O_NONBLOCK);

    sockaddr_un addr;
    std::memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    std::strncpy(addr.sun_path, _path.c_str(), sizeof(addr.sun_path) - 1);

    if (bind(_listenFd, (sockaddr*)&addr, sizeof(addr)) < 0) {
        close(_listenFd);
        _listenFd = -1;
        return;
    }

    listen(_listenFd, 16);
    chmod(_path.c_str(), 0600);
}

StateSocket::~StateSocket()
{
    closeAllClients();
    if (_listenFd >= 0) {
        close(_listenFd);
        _listenFd = -1;
    }
    unlink(_path.c_str());
}

std::string StateSocket::resolvePath() const
{
    const char* env = std::getenv("AEOLUS_SOCKET");
    if (env && *env)
        return env;

    const char* xdg = std::getenv("XDG_RUNTIME_DIR");
    if (xdg && *xdg)
        return std::string(xdg) + "/aeolus.sock";

    return "/tmp/aeolus-" + std::to_string(getuid()) + ".sock";
}

void StateSocket::sendToClient(int fd, const std::string& data)
{
    ssize_t sent = send(fd, data.c_str(), data.size(), MSG_NOSIGNAL | MSG_DONTWAIT);
    if (sent < 0 || (size_t)sent != data.size()) {
        closeClient(fd);
    }
}

void StateSocket::closeClient(int fd)
{
    close(fd);
    for (auto it = _clients.begin(); it != _clients.end(); ++it) {
        if (it->fd == fd) {
            _clients.erase(it);
            break;
        }
    }
}

void StateSocket::closeAllClients()
{
    for (auto& c : _clients)
        close(c.fd);
    _clients.clear();
}

juce::String StateSocket::replaceNewlines(const juce::String& s) const
{
    juce::String r = s;
    r = r.replace("\r\n", " ");
    r = r.replace("\n", " ");
    r = r.replace("\r", " ");
    return r;
}

std::string StateSocket::escapeJson(const juce::String& s) const
{
    std::string out;
    const char* utf8 = s.toUTF8();
    for (const char* p = utf8; *p; ++p) {
        unsigned char c = (unsigned char)*p;
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out += (char)c;
                }
                break;
        }
    }
    return out;
}

std::string StateSocket::buildJson(int seq) const
{
    auto* g = EngineGlobal::getInstance();
    if (!g)
        return "{}";

    auto* engine = g->getEngine();
    if (!engine)
        return "{}";

    std::ostringstream oss;
    oss << "{\"instance\":\"" << _instance << "\"";
    oss << ",\"seq\":" << seq;
    oss << ",\"step\":" << engine->getSequencer()->getCurrentStep();
    oss << ",\"steps\":" << engine->getSequencer()->getStepsCount();
    oss << ",\"volume\":" << formatFloat(engine->getVolume());
    oss << ",\"reverb\":" << formatFloat(engine->getReverbWet());
    oss << ",\"divisions\":[";

    int divCount = engine->getDivisionCount();
    for (int i = 0; i < divCount; ++i) {
        if (i > 0)
            oss << ",";
        auto* div = engine->getDivisionByIndex(i);
        oss << "{\"name\":\"" << escapeJson(replaceNewlines(div->getName())) << "\"";
        if (auto* param = div->getParamGain())
            oss << ",\"gain\":" << formatFloat(param->get());
        if (div->hasTremulant()) {
            oss << ",\"tremulant\":" << (div->isTremulantEnabled() ? "true" : "false");
        }
        oss << ",\"stops\":[";
        int stopCount = div->getStopsCount();
        for (int j = 0; j < stopCount; ++j) {
            if (j > 0)
                oss << ",";
            auto& stop = div->getStopByIndex(j);
            oss << "{\"name\":\"" << escapeJson(replaceNewlines(stop.getName())) << "\"";
            oss << ",\"on\":" << (stop.isEnabled() ? "true" : "false");
            oss << "}";
        }
        oss << "]}";
    }
    oss << "]}";
    return oss.str();
}

void StateSocket::handleCommand(const std::string& line)
{
    auto* g = EngineGlobal::getInstance();
    auto* engine = g ? g->getEngine() : nullptr;
    if (!engine)
        return;

    const auto cmd = juce::JSON::parse(juce::String::fromUTF8(line.c_str()));
    const auto gain = cmd.getProperty("gain", {});

    if (gain.isObject()) {
        const auto div = gain.getProperty("division", {});
        const auto value = gain.getProperty("value", {});
        if ((div.isInt() || div.isInt64()) && (value.isDouble() || value.isInt() || value.isInt64())) {
            const int d = (int)div;
            if (juce::isPositiveAndBelow(d, engine->getDivisionCount())) {
                if (auto* param = engine->getDivisionByIndex(d)->getParamGain())
                    param->setValueNotifyingHost(juce::jlimit(0.0f, 1.0f, (float)(double)value));
            }
        }
    }
}

void StateSocket::tick()
{
    if (_listenFd < 0)
        return;

    auto* g = EngineGlobal::getInstance();
    if (!g)
        return;

    auto* engine = g->getEngine();
    if (!engine)
        return;

    // Accept new clients (up to 16 total).
    std::vector<int> newClients;
    while ((int)_clients.size() < 16) {
        int fd = accept(_listenFd, nullptr, nullptr);
        if (fd < 0)
            break;
        int flags = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        _clients.push_back({fd, {}});
        newClients.push_back(fd);
    }

    // Read commands, then drop clients that hung up (otherwise dead
    // connections would only be noticed on the next state change and could
    // exhaust the client slots). Pending data is read before the hang-up is
    // honoured, so a client may connect, write a command and close at once.
    for (size_t i = 0; i < _clients.size();) {
        pollfd p { _clients[i].fd, POLLIN, 0 };
        bool dead = false;
        if (::poll(&p, 1, 0) > 0) {
            if (p.revents & POLLIN) {
                auto& in = _clients[i].input;
                char buf[1024];
                for (;;) {
                    ssize_t n = recv(p.fd, buf, sizeof(buf), MSG_DONTWAIT);
                    if (n > 0) {
                        in.append(buf, (size_t)n);
                        continue;
                    }
                    dead = n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK);
                    break;
                }
                size_t nl;
                while ((nl = in.find('\n')) != std::string::npos) {
                    handleCommand(in.substr(0, nl));
                    in.erase(0, nl + 1);
                }
                // A client sending garbage without newlines is dropped.
                dead = dead || in.size() > 4096;
            } else if (p.revents & (POLLHUP | POLLERR | POLLNVAL)) {
                dead = true;
            }
        }
        if (dead) {
            const int fd = _clients[i].fd;
            close(fd);
            _clients.erase(_clients.begin() + (long)i);
            newClients.erase(std::remove(newClients.begin(), newClients.end(), fd), newClients.end());
        } else {
            ++i;
        }
    }

    // Build state and detect change (excluding seq).
    std::string body = buildJson(0);
    bool changed = !_hasLast || body != _lastBody;
    if (changed) {
        _seq++;
        _lastBody = body;
        _hasLast = true;
    }
    std::string fullLine = buildJson(_seq) + "\n";

    // Send to new clients.
    for (int fd : newClients) {
        sendToClient(fd, fullLine);
    }

    // If changed, send to existing clients (not the new ones).
    if (changed) {
        std::vector<int> toSend;
        for (const auto& c : _clients) {
            bool isNew = false;
            for (int nfd : newClients) {
                if (c.fd == nfd) {
                    isNew = true;
                    break;
                }
            }
            if (!isNew)
                toSend.push_back(c.fd);
        }
        for (int fd : toSend) {
            sendToClient(fd, fullLine);
        }
    }
}

AEOLUS_NAMESPACE_END

#endif // JUCE_LINUX
