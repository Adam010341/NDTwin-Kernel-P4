#include "ndt_core/routing_management/Controller.hpp"
#include "ndt_core/routing_management/FlowRoutingManager.hpp"
#include "utils/Logger.hpp"
#include "spdlog/spdlog.h"

Controller::Controller(std::shared_ptr<FlowRoutingManager> flowRoutingManager)
    : m_flowRoutingManager(std::move(flowRoutingManager)),
      dispatcher_(
          // SenderFn: batch send using your existing flow manager
          [this](const std::vector<FlowJob>& batch) {
              for (const auto& job : batch)
              {
                  // [Co-developed with claude code -- Adam]
                  // Every one of these returns an OpResult and every one of them used to be
                  // discarded here, which quietly undid Phase 2: FlowRoutingManager was changed
                  // from void to OpResult, and HttpRoutingStrategyBase taught to parse curl's real
                  // status, so that a rejected rule could be told apart from an unreachable
                  // controller -- and then this lambda threw the answer away. HttpSession's own
                  // comment claimed the outcome was "logged per entry with the dpid and the
                  // controller's reply"; it was not. The strategy logged its own failure with the
                  // endpoint, but nothing tied it to the job, and nothing could act on it.
                  //
                  // This is the last place the result exists: FlowJob is fire-and-forget, so
                  // reporting it to the original caller needs a completion handle. Logging it with
                  // the dpid and operation is what can be done here, and it is what makes
                  // check_logs.py able to fail a run on a rejected rule.
                  OpResult result;
                  const char* what = "install";
                  switch (job.op)
                  {
                  case FlowOp::Install:
                      result = m_flowRoutingManager->installAnEntry(job.dpid,
                                                                    job.priority,
                                                                    job.match,
                                                                    job.actions,
                                                                    job.idleTimeout);
                      break;
                  case FlowOp::Modify:
                      what = "modify";
                      result = m_flowRoutingManager->modifyAnEntry(job.dpid,
                                                                   job.priority,
                                                                   job.match,
                                                                   job.actions);
                      break;
                  case FlowOp::Delete:
                      what = "delete";
                      result = m_flowRoutingManager->deleteAnEntry(job.dpid,
                                                                   job.match,
                                                                   job.priority);
                      break;
                  }

                  if (!result.ok)
                  {
                      SPDLOG_LOGGER_ERROR(Logger::instance(),
                                          "dispatched {} failed for dpid {} (priority {}): "
                                          "HTTP {} -- {}",
                                          what,
                                          job.dpid,
                                          job.priority,
                                          result.httpStatus,
                                          result.message);
                  }
              }
              // (Optional) fence/Barrier here if your southbound supports it
          },
          /*burstSize*/ 2000)
{
    dispatcher_.start();
}

Controller::~Controller()
{
    dispatcher_.stop();
}
