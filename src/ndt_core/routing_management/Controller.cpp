#include "ndt_core/routing_management/Controller.hpp"
#include "ndt_core/routing_management/FlowRoutingManager.hpp"
#include "utils/Logger.hpp"
#include "spdlog/spdlog.h"

Controller::Controller(std::shared_ptr<FlowRoutingManager> flowRoutingManager)
    : m_flowRoutingManager(std::move(flowRoutingManager)),
      dispatcher_(
          // SenderFn: batch send using your existing flow manager
          [this](const std::vector<FlowJob>& batch) {
              // [Co-developed with claude code -- Adam]
              // doc/KNOWN-ISSUES.md C-4. Tallied over the batch and reported once below rather
              // than once per job: a burst is 2000 entries, and a line each would be its own
              // outage. One worker per dpid, so a batch names one switch.
              std::size_t unconfirmed = 0;
              uint64_t unconfirmedDpid = 0;

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

                  // [Co-developed with claude code -- Adam]
                  // Every outcome, not only the failures. The log line below is for a human
                  // reading kernel.log after the fact; this is for a program asking the API,
                  // which is the half A-7 says is missing. Successes come here too because this
                  // is the only place a job and its OpResult are both in scope -- see the note
                  // on DispatchOutcomeLog::record.
                  outcomes_.record(job, result);

                  // job.token != 0 as well as the two result bits: only an install mints a
                  // token, so a modify or a delete withholds nothing from the view and must not
                  // be counted here. Saying "these rows are withheld" about entries that have no
                  // cache row is the same kind of over-claim the ticket is about, pointed the
                  // other way.
                  if (job.token != 0 && result.ok && !result.confirmsProgramming)
                  {
                      ++unconfirmed;
                      unconfirmedDpid = job.dpid;
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

              // [Co-developed with claude code -- Adam]
              // doc/KNOWN-ISSUES.md C-4. The "why" belongs here, because this is the only place
              // the control plane's answer is in scope. Deliberately not worded with "failed":
              // check_logs.py fails a run on a dispatched-*-failed line, and an entry the far end
              // accepted has not failed -- it is merely unwitnessed, which is a different thing
              // to tell an operator and leads to a different action.
              if (unconfirmed > 0)
              {
                  SPDLOG_LOGGER_WARN(Logger::instance(),
                                     "{} of {} dispatched flow entries for dpid {} were accepted "
                                     "by the control plane, but this plane's acceptance is not "
                                     "evidence the switch programmed them -- it answers before "
                                     "the switch adjudicates. They are withheld from "
                                     "get_switch_openflow_table_entries until a poll observes "
                                     "them (KNOWN-ISSUES C-4).",
                                     unconfirmed,
                                     batch.size(),
                                     unconfirmedDpid);
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
