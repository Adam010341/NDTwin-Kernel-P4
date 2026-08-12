/**
 * The OpenAI API key must never reach a log sink.
 *
 * [Co-developed with claude code -- Adam]
 *
 * LLMAgent's constructor used to do this, at INFO -- the default-on level:
 *
 *     char* apiKey = std::getenv("OPENAI_API_KEY");
 *     SPDLOG_LOGGER_INFO(Logger::instance(), "api_key={}", apiKey);
 *     if (apiKey == nullptr) { ... }
 *
 * so every AI-enabled kernel start wrote the secret into the kernel log, and this project
 * routinely pastes log excerpts into doc/debug-log/ and handoff documents. The call also ran
 * *before* the null check on the next line; formatting a null `char*` through fmt is not a
 * printable "(null)" path.
 *
 * Asserting on a log sink rather than on the source is deliberate: the thing worth pinning is
 * that no sink ever sees the value, which is a property of the emitted records, not of one
 * statement. Any future `api_key={}` anywhere in the construction path fails this test, not
 * just the line that was removed.
 *
 * Note on levels: tests/test_LoggerEnvironment.cpp initialises the global logger at
 * `spdlog::level::off`, so a capture sink attached at that level records nothing and this test
 * would pass no matter what the code did. It therefore raises the level to trace for the
 * duration and restores it -- without that, the test could not fail.
 */

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>

#include <gtest/gtest.h>
#include <spdlog/sinks/ringbuffer_sink.h>

#include "ndt_core/intent_translator/LLMAgent.hpp"
#include "utils/Logger.hpp"

namespace
{

/// A value distinctive enough that finding it in a log record cannot be a coincidence.
constexpr const char* kSentinelKey = "sk-proj-SENTINEL-must-never-be-logged-2f8a1c";

/**
 * @brief Captures every record the global logger emits while it is alive, at trace level.
 *
 * Restores the logger's previous level and sink list on destruction, so the rest of the suite
 * runs against the `off` level test_LoggerEnvironment installed.
 */
class LogCapture
{
  public:
    LogCapture()
        : m_logger(Logger::instance()),
          m_savedLevel(m_logger->level()),
          m_sink(std::make_shared<spdlog::sinks::ringbuffer_sink_mt>(256))
    {
        m_logger->sinks().push_back(m_sink);
        m_logger->set_level(spdlog::level::trace);
    }

    ~LogCapture()
    {
        m_logger->set_level(m_savedLevel);
        auto& sinks = m_logger->sinks();
        for (auto it = sinks.begin(); it != sinks.end(); ++it)
        {
            if (*it == m_sink)
            {
                sinks.erase(it);
                break;
            }
        }
    }

    /// Every formatted record captured so far, concatenated.
    std::string text() const
    {
        std::string all;
        for (const auto& line : m_sink->last_formatted())
        {
            all += line;
        }
        return all;
    }

    std::size_t recordCount() const { return m_sink->last_formatted().size(); }

  private:
    std::shared_ptr<spdlog::logger> m_logger;
    spdlog::level::level_enum m_savedLevel;
    std::shared_ptr<spdlog::sinks::ringbuffer_sink_mt> m_sink;
};

/// LLMAgent's constructor throws unless the system prompt file exists, so give it one.
class TempPromptFile
{
  public:
    TempPromptFile()
        : m_path(std::filesystem::temp_directory_path() /
                 "ndtwin_test_llm_prompt_apikey_not_logged.txt")
    {
        std::ofstream out(m_path);
        out << "you are a test prompt\n";
    }

    ~TempPromptFile()
    {
        std::error_code ec;
        std::filesystem::remove(m_path, ec);
    }

    std::string path() const { return m_path.string(); }

  private:
    std::filesystem::path m_path;
};

/// Sets OPENAI_API_KEY for the duration and restores whatever was there before.
class ScopedApiKeyEnv
{
  public:
    explicit ScopedApiKeyEnv(const char* value)
    {
        const char* previous = std::getenv("OPENAI_API_KEY");
        m_had = previous != nullptr;
        if (m_had)
        {
            m_previous = previous;
        }
        ::setenv("OPENAI_API_KEY", value, 1);
    }

    ~ScopedApiKeyEnv()
    {
        if (m_had)
        {
            ::setenv("OPENAI_API_KEY", m_previous.c_str(), 1);
        }
        else
        {
            ::unsetenv("OPENAI_API_KEY");
        }
    }

  private:
    bool m_had = false;
    std::string m_previous;
};

} // namespace

TEST(ApiKeyNotLoggedTest, ConstructingAnLLMAgentDoesNotWriteTheKeyToAnySink)
{
    TempPromptFile prompt;
    ScopedApiKeyEnv env(kSentinelKey);

    LogCapture capture;
    LLMAgent agent(prompt.path(), nullptr, nullptr, "gpt-4o-mini");

    EXPECT_EQ(capture.text().find(kSentinelKey), std::string::npos)
        << "the OPENAI_API_KEY value reached a log sink; captured log was:\n"
        << capture.text();
}

/**
 * Guards the guard. If the capture rig itself stopped working -- wrong level, sink not attached,
 * ringbuffer empty -- the test above would pass vacuously and keep passing after the plaintext
 * log was restored. This asserts the rig records the constructor's *other* messages, so an empty
 * capture is a failure here rather than a silent pass there.
 */
TEST(ApiKeyNotLoggedTest, TheCaptureRigActuallyRecordsTheConstructorsOwnLogging)
{
    TempPromptFile prompt;
    ScopedApiKeyEnv env(kSentinelKey);

    LogCapture capture;
    LLMAgent agent(prompt.path(), nullptr, nullptr, "gpt-4o-mini");

    EXPECT_GT(capture.recordCount(), 0u)
        << "the capture sink recorded nothing at all, so the assertion in "
           "ConstructingAnLLMAgentDoesNotWriteTheKeyToAnySink could not have failed";
    EXPECT_NE(capture.text().find("LLMAgent initialized"), std::string::npos)
        << "expected the constructor's own debug line in the capture; got:\n"
        << capture.text();
}

/**
 * The accept path's companion: a missing key must still be reported, and reported without
 * dereferencing the null pointer the old ordering formatted first.
 */
TEST(ApiKeyNotLoggedTest, AMissingKeyThrowsRatherThanFormattingANullPointer)
{
    TempPromptFile prompt;
    const char* previous = std::getenv("OPENAI_API_KEY");
    const std::string saved = previous ? previous : "";
    const bool had = previous != nullptr;
    ::unsetenv("OPENAI_API_KEY");

    LogCapture capture;
    EXPECT_THROW(LLMAgent(prompt.path(), nullptr, nullptr, "gpt-4o-mini"), std::runtime_error);

    if (had)
    {
        ::setenv("OPENAI_API_KEY", saved.c_str(), 1);
    }
}
