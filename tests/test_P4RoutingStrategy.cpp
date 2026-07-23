// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
#include <gtest/gtest.h>
#include "ndt_core/routing_management/P4RoutingStrategy.hpp"
#include "utils/Logger.hpp"
#include <nlohmann/json.hpp>
#include <string>

using json = nlohmann::json;

class MockP4RoutingStrategy : public P4RoutingStrategy
{
public:
    MockP4RoutingStrategy(const std::string& apiUrl) : P4RoutingStrategy(apiUrl) {}
    
    std::string lastExecutedCommand;

protected:
    void executeCommand(const std::string& cmd) override
    {
        lastExecutedCommand = cmd;
    }
};

class P4RoutingStrategyTest : public ::testing::Test
{
protected:
    static void SetUpTestSuite()
    {
        LogConfig cfg;
        cfg.level = spdlog::level::off; // disable logs for tests to keep it clean
        Logger::init(cfg);
    }
};

TEST_F(P4RoutingStrategyTest, InstallAnEntryGeneratesCorrectCurl)
{
    MockP4RoutingStrategy strategy("localhost:8081");
    json match = {{"in_port", 1}};
    json action = {{{"type", "OUTPUT"}, {"port", 2}}};
    
    strategy.installAnEntry(1234, 100, match, action, 30);
    
    EXPECT_TRUE(strategy.lastExecutedCommand.find("curl -s -X POST http://localhost:8081/stats/flowentry/add") != std::string::npos);
    EXPECT_TRUE(strategy.lastExecutedCommand.find("\"dpid\":1234") != std::string::npos);
    EXPECT_TRUE(strategy.lastExecutedCommand.find("\"priority\":100") != std::string::npos);
    EXPECT_TRUE(strategy.lastExecutedCommand.find("\"idle_timeout\":30") != std::string::npos);
}

TEST_F(P4RoutingStrategyTest, DeleteAnEntryGeneratesCorrectCurl)
{
    MockP4RoutingStrategy strategy("localhost:8081");
    json match = {{"in_port", 1}};
    
    strategy.deleteAnEntry(1234, match, 100);
    
    EXPECT_TRUE(strategy.lastExecutedCommand.find("curl -s -X POST http://localhost:8081/stats/flowentry/delete_strict") != std::string::npos);
    EXPECT_TRUE(strategy.lastExecutedCommand.find("\"dpid\":1234") != std::string::npos);
    EXPECT_TRUE(strategy.lastExecutedCommand.find("\"priority\":100") != std::string::npos);
}
