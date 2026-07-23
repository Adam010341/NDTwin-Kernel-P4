// [P4 Proxy Integration] Developed in collaboration with Gemini 3.1 Pro.
#include <gtest/gtest.h>
#include "ndt_core/routing_management/OpenFlowRoutingStrategy.hpp"
#include "utils/Logger.hpp"
#include <nlohmann/json.hpp>
#include <string>

using json = nlohmann::json;

class MockOpenFlowRoutingStrategy : public OpenFlowRoutingStrategy
{
public:
    MockOpenFlowRoutingStrategy(const std::string& apiUrl) : OpenFlowRoutingStrategy(apiUrl) {}
    
    std::string lastExecutedCommand;

protected:
    void executeCommand(const std::string& cmd) override
    {
        lastExecutedCommand = cmd;
    }
};

class OpenFlowRoutingStrategyTest : public ::testing::Test
{
protected:
    static void SetUpTestSuite()
    {
        LogConfig cfg;
        cfg.level = spdlog::level::off; // disable logs for tests to keep it clean
        Logger::init(cfg);
    }
};

TEST_F(OpenFlowRoutingStrategyTest, InstallAnEntryGeneratesCorrectCurl)
{
    MockOpenFlowRoutingStrategy strategy("localhost:8080");
    json match = {{"in_port", 1}};
    json action = {{{"type", "OUTPUT"}, {"port", 2}}};
    
    strategy.installAnEntry(1234, 100, match, action, 30);
    
    EXPECT_TRUE(strategy.lastExecutedCommand.find("curl -s -X POST http://localhost:8080/stats/flowentry/add") != std::string::npos);
    EXPECT_TRUE(strategy.lastExecutedCommand.find("\"dpid\":1234") != std::string::npos);
    EXPECT_TRUE(strategy.lastExecutedCommand.find("\"priority\":100") != std::string::npos);
    EXPECT_TRUE(strategy.lastExecutedCommand.find("\"idle_timeout\":30") != std::string::npos);
}

TEST_F(OpenFlowRoutingStrategyTest, DeleteAnEntryGeneratesCorrectCurl)
{
    MockOpenFlowRoutingStrategy strategy("localhost:8080");
    json match = {{"in_port", 1}};
    
    strategy.deleteAnEntry(1234, match, 100);
    
    EXPECT_TRUE(strategy.lastExecutedCommand.find("curl -s -X POST http://localhost:8080/stats/flowentry/delete_strict") != std::string::npos);
    EXPECT_TRUE(strategy.lastExecutedCommand.find("\"dpid\":1234") != std::string::npos);
    EXPECT_TRUE(strategy.lastExecutedCommand.find("\"priority\":100") != std::string::npos);
}
