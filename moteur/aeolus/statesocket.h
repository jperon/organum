// ----------------------------------------------------------------------------
//
//  State socket publisher for Aeolus (Linux only).
//
// ----------------------------------------------------------------------------

#pragma once

#include "aeolus/globals.h"

#if JUCE_LINUX

#include <sys/socket.h>
#include <sys/un.h>

#include <string>
#include <vector>

AEOLUS_NAMESPACE_BEGIN

class EngineGlobal;

/**
 * @brief Publishes the organ state as JSON lines over a Unix socket.
 *
 * Runs entirely on the message thread (driven by EngineGlobal's timer).
 * No audio-thread locking.
 *
 * Clients may send commands, one JSON object per line:
 *   {"gain":{"division":<index>,"value":<0..1>}}
 */
class StateSocket
{
public:

    StateSocket();
    ~StateSocket();

    /** Called every ~100 ms on the message thread. */
    void tick();

private:

    struct Client
    {
        int fd = -1;
        std::string input;  ///< Partial command line received from the client.
    };

    void handleCommand(const std::string& line);

    void sendToClient(int fd, const std::string& data);
    void closeClient(int fd);
    void closeAllClients();

    std::string buildJson(int seq) const;
    std::string escapeJson(const juce::String& s) const;
    juce::String replaceNewlines(const juce::String& s) const;

    std::string resolvePath() const;

    int _listenFd = -1;
    std::string _path;
    std::string _instance;

    std::vector<Client> _clients;

    int _seq = 0;
    std::string _lastBody;
    bool _hasLast = false;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(StateSocket)
};

AEOLUS_NAMESPACE_END

#endif // JUCE_LINUX
