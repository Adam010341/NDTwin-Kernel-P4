# Agent A mutation evidence

Every row below was produced by applying exactly one edit to production code,
rebuilding, running the whole `test_routing_strategy` binary, and reverting.
`observed failure` text is copied from stdout, never predicted.

| test name | mutation file:line | old -> new | observed failure |
|---|---|---|---|
| `EveryTaskTypeSurvivesARoundTripThroughItsWireName` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:149` | `return "GetPath"` -> `return "getPath"` | `[  FAILED  ] LLMResponseEnumsTest.EveryTaskTypeSurvivesARoundTripThroughItsWireName (0 ms)` (+1 others) | <!-- also broke 1 other test(s): LLMResponseParsingTest.AnAnswerRoundTripsThroughJsonWithItsTasksIntact -->
| `AnUnmappedTaskTypeIsNamedRatherThanRenderedAsAnInteger` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:227` | `default: return "Unknown"` -> `default: return "unmapped"` | `[  FAILED  ] LLMResponseEnumsTest.AnUnmappedTaskTypeIsNamedRatherThanRenderedAsAnInteger (0 ms)` | <!-- sole failure -->
| `TaskNamesAreCaseSensitiveSoNearMissesAreRejected` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:294` | `if (s == "GetPath")` -> `if (s == "GetPath" || s == "getPath")` | `[  FAILED  ] LLMResponseEnumsTest.TaskNamesAreCaseSensitiveSoNearMissesAreRejected (0 ms)` | <!-- sole failure -->
| `EveryTaskTypeSurvivesARoundTripThroughItsWireName` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:149` | `return "GetPath"` -> `return "getPath"` | `[  FAILED  ] LLMResponseEnumsTest.EveryTaskTypeSurvivesARoundTripThroughItsWireName (0 ms)` (+1 others) | <!-- also broke 1 other test(s): LLMResponseParsingTest.AnAnswerRoundTripsThroughJsonWithItsTasksIntact -->
| `AnUnmappedTaskTypeIsNamedRatherThanRenderedAsAnInteger` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:227` | `default: return "Unknown"` -> `default: return "unmapped"` | `[  FAILED  ] LLMResponseEnumsTest.AnUnmappedTaskTypeIsNamedRatherThanRenderedAsAnInteger (0 ms)` | <!-- sole failure -->
| `AnUnknownTaskNameIsRejectedRatherThanDefaultingToATask` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:441` | `throw runtime_error("unknown task type")` -> `return DISABLE_SWITCH` | `[  FAILED  ] LLMResponseEnumsTest.AnUnknownTaskNameIsRejectedRatherThanDefaultingToATask (0 ms)` (+1 others) | <!-- also broke 1 other test(s): LLMResponseEnumsTest.TaskNamesAreCaseSensitiveSoNearMissesAreRejected -->
| `TaskNamesAreCaseSensitiveSoNearMissesAreRejected` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:294` | `if (s == "GetPath")` -> `if (s == "GetPath" || s == "getPath")` | `[  FAILED  ] LLMResponseEnumsTest.TaskNamesAreCaseSensitiveSoNearMissesAreRejected (0 ms)` | <!-- sole failure -->
| `EveryStateSurvivesARoundTripAndUnknownOnesAreRejected` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:29` | `return "validation"` -> `return "Validation"` | `[  FAILED  ] LLMResponseEnumsTest.EveryStateSurvivesARoundTripAndUnknownOnesAreRejected (0 ms)` | <!-- sole failure -->
| `ADiscussionReplyBecomesADiscussionCarryingItsPrompt` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:2378` | `d.prompt = j.at("prompt")` -> `d.prompt = ""` | `[  FAILED  ] LLMResponseParsingTest.ADiscussionReplyBecomesADiscussionCarryingItsPrompt (0 ms)` | <!-- sole failure -->
| `AValidationReplyCarriesItsErrorMessageFromTheErrorField` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:2400` | `v.errorMsg = j.at("error")` -> `v.errorMsg = ""` | `[  FAILED  ] LLMResponseParsingTest.AValidationReplyCarriesItsErrorMessageFromTheErrorField (0 ms)` | <!-- sole failure -->
| `AReplyWithNoStateIsRejectedRatherThanAssumedToBeAnAnswer` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:2443` | `stateFromString(j.at("state"))` -> `stateFromString(j.value("state","discussion"))` | **NO-FAILURE** | <!-- needs another mutation or deletion -->
| `ANullResponsePointerSerialisesToJsonNullRatherThanAnEmptyObject` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:2420` | `j = nullptr` -> `j = json::object()` | `[  FAILED  ] LLMResponseParsingTest.ANullResponsePointerSerialisesToJsonNullRatherThanAnEmptyObject (0 ms)` | <!-- sole failure -->
| `ANullTaskPointerSerialisesToJsonNullRatherThanAnEmptyObject` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:1974` | `j = nullptr` -> `j = json::object()` | `[  FAILED  ] LLMResponseParsingTest.ANullTaskPointerSerialisesToJsonNullRatherThanAnEmptyObject (0 ms)` | <!-- sole failure -->
| `AnAnswerMarkedInvalidDiscardsTheTasksItStillCarries` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:2344` | `if (ans.valid)` -> `if (true)` | `[  FAILED  ] LLMResponseParsingTest.AnAnswerMarkedInvalidDiscardsTheTasksItStillCarries (0 ms)` | <!-- sole failure -->
| `ValidIsReadNumericallySoOneAndZeroBothWork` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:2343` | `get<int>()` -> `get<bool>()` | `[  FAILED  ] LLMResponseParsingTest.ValidIsReadNumericallySoOneAndZeroBothWork (0 ms)` | <!-- sole failure -->
| `AStringlyTypedValidIsRejectedRatherThanReadAsTruthy` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:2343` | `get<int>()` -> `is_string() || get<int>()` | `[  FAILED  ] LLMResponseParsingTest.AStringlyTypedValidIsRejectedRatherThanReadAsTruthy (0 ms)` | <!-- sole failure -->
| `AnEmptyTaskListIsAcceptedButAMissingOneIsNot` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:2344` | `if (ans.valid)` -> `if (ans.valid && j.contains("tasks"))` | `[  FAILED  ] LLMResponseParsingTest.AnEmptyTaskListIsAcceptedButAMissingOneIsNot (0 ms)` | <!-- sole failure -->
| `ANullTasksFieldYieldsNoTasksAndNoErrorDocumentsCurrentBehaviour` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:2346` | `for (... : j.at("tasks"))` -> `for (... : j.at("tasks").get_ref<const array_t&>())` | `[  FAILED  ] LLMResponseParsingTest.ANullTasksFieldYieldsNoTasksAndNoErrorDocumentsCurrentBehaviour (0 ms)` | <!-- sole failure -->
| `DeserialisingTwiceIntoTheSameAnswerAppendsDocumentsCurrentBehaviour` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:2346` | `(no clear)` -> `ans.tasks.clear() before the loop` | `[  FAILED  ] LLMResponseParsingTest.DeserialisingTwiceIntoTheSameAnswerAppendsDocumentsCurrentBehaviour (0 ms)` | <!-- sole failure -->
| `ATasksEntryThatIsNotATaskObjectIsRejected` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:2150` | `taskTypeFromString(j.at("type"))` -> `j.is_object() ? j.at("type") : "GetAllHosts"` | **NO-FAILURE** | <!-- needs another mutation or deletion -->
| `OneUnparseableTaskRejectsTheWholeReplyRatherThanPartOfIt` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:2349` | `from_json(taskJson, task);` -> `try { from_json(...) } catch { continue; }` | `[  FAILED  ] LLMResponseParsingTest.OneUnparseableTaskRejectsTheWholeReplyRatherThanPartOfIt (0 ms)` (+8 others) | <!-- also broke 8 other test(s): LLMResponseParsingTest.ATaskWithNoOrderIsRejectedBecauseTheOrderDecidesWhatRunsFirst, LLMResponseParsingTest.ATaskThatNeedsAParameterIsRejectedWhenItIsMissingOrNull, LLMResponseParsingTest.ADeviceNameGivenAsANumberIsRejectedRatherThanStringified, LLMResponseParsingTest.TheStringActionFormRyuUsesIsRejectedHereDocumentsCurrentBehaviour, LLMResponseParsingTest.AnActionMissingItsPortIsRejectedRatherThanDefaultingToZero, LLMResponseParsingTest.ARerouteWithANonStringHopIsRejectedRatherThanPartiallyParsed, LLMResponseParsingTest.AKGivenAsAStringIsRejectedRatherThanParsedOutOfTheText, LLMResponseParsingTest.ATasksEntryThatIsNotATaskObjectIsRejected -->
| `SeveralTasksArriveInTheOrderTheyWereListed` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:2350` | `tasks.push_back(...)` -> `tasks.insert(tasks.begin(), ...)` | `[  FAILED  ] LLMResponseParsingTest.SeveralTasksArriveInTheOrderTheyWereListed (0 ms)` (+1 others) | <!-- also broke 1 other test(s): LLMResponseParsingTest.AnAnswerRoundTripsThroughJsonWithItsTasksIntact -->
| `AnAnswerRoundTripsThroughJsonWithItsTasksIntact` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:2329` | `{"explanation", ans.explanation}` -> `{"explanation", ""}` | `[  FAILED  ] LLMResponseParsingTest.AnAnswerRoundTripsThroughJsonWithItsTasksIntact (0 ms)` | <!-- sole failure -->
| `NothingAModelCouldSendCausesAnythingWorseThanAnException` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:2452` | `p = make_llm_from_json<Validation>(j)` -> `p = nullptr` | `[  FAILED  ] LLMResponseParsingTest.NothingAModelCouldSendCausesAnythingWorseThanAnException (0 ms)` (+1 others) | <!-- also broke 1 other test(s): LLMResponseParsingTest.AValidationReplyCarriesItsErrorMessageFromTheErrorField -->
| `EachTaskNameProducesItsOwnConcreteType` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:2198` | `make_from_json<GetPathTask>` -> `make_from_json<GetPathSwitchCountTask>` | `[  FAILED  ] LLMResponseParsingTest.EachTaskNameProducesItsOwnConcreteType (0 ms)` | <!-- sole failure -->
| `ATaskWithNoOrderIsRejectedBecauseTheOrderDecidesWhatRunsFirst` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:488` | `j.at("order").get<uint16_t>()` -> `j.value("order", uint16_t{0})` | `[  FAILED  ] LLMResponseParsingTest.ATaskWithNoOrderIsRejectedBecauseTheOrderDecidesWhatRunsFirst (0 ms)` | <!-- sole failure -->
| `OrderIsCarriedThroughForValuesBeyondASingleByte` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:488` | `get<uint16_t>()` -> `get<uint8_t>()` | `[  FAILED  ] LLMResponseParsingTest.OrderIsCarriedThroughForValuesBeyondASingleByte (0 ms)` (+1 others) | <!-- also broke 1 other test(s): LLMResponseParsingTest.ANegativeOrderWrapsToItsUnsignedValueDocumentsCurrentBehaviour -->
| `ANegativeOrderWrapsToItsUnsignedValueDocumentsCurrentBehaviour` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:471` | `uint16_t order;` -> `int32_t order;` | **NO-FAILURE** | <!-- needs another mutation or deletion -->
| `AResultSuppliedByTheModelIsDiscardedRatherThanTrusted` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:489` | `t.result = ""` -> `t.result = j.value("result", "")` | `[  FAILED  ] LLMResponseParsingTest.AResultSuppliedByTheModelIsDiscardedRatherThanTrusted (0 ms)` | <!-- sole failure -->
| `ATaskThatTakesNoParametersDoesNotRequireAParametersObject` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:821` | `(no parameters access)` -> `j.at("parameters");` | `[  FAILED  ] LLMResponseParsingTest.ATaskThatTakesNoParametersDoesNotRequireAParametersObject (0 ms)` | <!-- sole failure -->
| `ATaskThatNeedsAParameterIsRejectedWhenItIsMissingOrNull` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:515` | `j.at("parameters").at("device_name")` -> `j.value("parameters",{}).value("device_name","")` | `[  FAILED  ] LLMResponseParsingTest.ATaskThatNeedsAParameterIsRejectedWhenItIsMissingOrNull (0 ms)` | <!-- sole failure -->
| `ADeviceNameGivenAsANumberIsRejectedRatherThanStringified` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:?` | `.at("state").get<std::string>()` -> `.at("state").dump()` | **abort-anchor** | <!-- needs another mutation or deletion -->
| `AnInstallFlowEntryCarriesItsDeviceMatchPriorityAndAction` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:641` | `task.deviceName = j.at(...)("device_name")` -> `task.deviceName = ""` | `[  FAILED  ] LLMResponseParsingTest.AnInstallFlowEntryCarriesItsDeviceMatchPriorityAndAction (0 ms)` | <!-- sole failure -->
| `AnEmptyActionsArrayMeansDropAndIsSignalledByPortMinusOne` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:652` | `actionOutPort = -1 (else arm)` -> `actionOutPort = 0` | `[  FAILED  ] LLMResponseParsingTest.AnEmptyActionsArrayMeansDropAndIsSignalledByPortMinusOne (0 ms)` | <!-- sole failure -->
| `OnlyTheFirstActionIsReadAndTheRestAreSilentlyIgnored` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:647` | `actions[0].at("port")` -> `actions.back().at("port")` | `[  FAILED  ] LLMResponseParsingTest.OnlyTheFirstActionIsReadAndTheRestAreSilentlyIgnored (0 ms)` | <!-- sole failure -->
| `TheStringActionFormRyuUsesIsRejectedHereDocumentsCurrentBehaviour` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:644` | `if (!actions.empty())` -> `if (!actions.empty() && !actions[0].is_string())` | `[  FAILED  ] LLMResponseParsingTest.TheStringActionFormRyuUsesIsRejectedHereDocumentsCurrentBehaviour (0 ms)` | <!-- sole failure -->
| `AnActionMissingItsPortIsRejectedRatherThanDefaultingToZero` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:647` | `actions[0].at("port")` -> `actions[0].value("port", 0)` | `[  FAILED  ] LLMResponseParsingTest.AnActionMissingItsPortIsRejectedRatherThanDefaultingToZero (0 ms)` | <!-- sole failure -->
| `APriorityAboveSixteenBitsWrapsDocumentsCurrentBehaviour` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:611` | `uint16_t priority;` -> `uint32_t priority;` | **NO-FAILURE** | <!-- needs another mutation or deletion -->
| `AMatchIsCarriedThroughVerbatimWithoutBeingValidated` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:742` | `task.match = j.at(...)("match")` -> `task.match = json::object()` | `[  FAILED  ] LLMResponseParsingTest.AMatchIsCarriedThroughVerbatimWithoutBeingValidated (0 ms)` | <!-- sole failure -->
| `AModifyFlowEntryTaskConstructsItselfAsAnInstallDocumentsCurrentBehaviour` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:664` | `type = INSTALL_FLOW_ENTRY (ctor)` -> `type = MODIFY_FLOW_ENTRY` | `[  FAILED  ] LLMResponseParsingTest.AModifyFlowEntryTaskConstructsItselfAsAnInstallDocumentsCurrentBehaviour (0 ms)` | <!-- sole failure -->
| `ARerouteCarriesEveryHopInTheOrderTheModelGaveThem` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:1251` | `new_path.get<vector<string>>()` -> `vector<string>(new_path.size())` | `[  FAILED  ] LLMResponseParsingTest.ARerouteCarriesEveryHopInTheOrderTheModelGaveThem (0 ms)` (+1 others) | <!-- also broke 1 other test(s): LLMResponseParsingTest.ARerouteWithANonStringHopIsRejectedRatherThanPartiallyParsed -->
| `ARerouteWithANonStringHopIsRejectedRatherThanPartiallyParsed` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:1251` | `new_path.get<vector<string>>()` -> `push_back(h.is_string() ? h : h.dump())` | `[  FAILED  ] LLMResponseParsingTest.ARerouteWithANonStringHopIsRejectedRatherThanPartiallyParsed (0 ms)` | <!-- sole failure -->
| `AGroupEntrysBucketsAreCarriedThroughVerbatim` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:1472` | `task.buckets = j.at(...)("buckets")` -> `task.buckets = json::array()` | `[  FAILED  ] LLMResponseParsingTest.AGroupEntrysBucketsAreCarriedThroughVerbatim (0 ms)` | <!-- sole failure -->
| `AMeterEntrysFlagsListIsCarriedThroughInOrder` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:1507` | `flags.get<vector<string>>()` -> `flags = {}` | `[  FAILED  ] LLMResponseParsingTest.AMeterEntrysFlagsListIsCarriedThroughInOrder (0 ms)` | <!-- sole failure -->
| `AKGivenAsAStringIsRejectedRatherThanParsedOutOfTheText` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:771` | `k.get<int>()` -> `is_string() ? stoi(k) : k.get<int>()` | `[  FAILED  ] LLMResponseParsingTest.AKGivenAsAStringIsRejectedRatherThanParsedOutOfTheText (0 ms)` | <!-- sole failure -->
| `ANegativeKIsCarriedThroughForTheCallerToDealWith` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:771` | `k.get<int>()` -> `std::max(0, k.get<int>())` | `[  FAILED  ] LLMResponseParsingTest.ANegativeKIsCarriedThroughForTheCallerToDealWith (0 ms)` | <!-- sole failure -->
| `AReplyWithNoStateIsRejectedRatherThanAssumedToBeAnAnswer` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:2443` | `(no state -> throws)` -> `if (!j.contains("state")) p = make_unique<Discussion>()` | `[  FAILED  ] LLMResponseParsingTest.AReplyWithNoStateIsRejectedRatherThanAssumedToBeAnAnswer (0 ms)` | <!-- sole failure -->
| `ANegativeOrderWrapsToItsUnsignedValueDocumentsCurrentBehaviour` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:488` | `(negative order wraps silently)` -> `if (order < 0) throw` | `[  FAILED  ] LLMResponseParsingTest.ANegativeOrderWrapsToItsUnsignedValueDocumentsCurrentBehaviour (0 ms)` | <!-- sole failure -->
| `ADeviceNameGivenAsANumberIsRejectedRatherThanStringified` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:1327` | `.at("state").get<std::string>()` -> `.at("state").dump()` | `[  FAILED  ] LLMResponseParsingTest.ADeviceNameGivenAsANumberIsRejectedRatherThanStringified (0 ms)` | <!-- sole failure -->
| `ATasksEntryThatIsNotATaskObjectIsRejected` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:2349` | `from_json(taskJson, task);` -> `try { from_json(...) } catch { continue; }` | `[  FAILED  ] LLMResponseParsingTest.ATasksEntryThatIsNotATaskObjectIsRejected (0 ms)` (+8 others) | <!-- also broke 8 other test(s): LLMResponseParsingTest.ATaskWithNoOrderIsRejectedBecauseTheOrderDecidesWhatRunsFirst, LLMResponseParsingTest.ATaskThatNeedsAParameterIsRejectedWhenItIsMissingOrNull, LLMResponseParsingTest.ADeviceNameGivenAsANumberIsRejectedRatherThanStringified, LLMResponseParsingTest.TheStringActionFormRyuUsesIsRejectedHereDocumentsCurrentBehaviour, LLMResponseParsingTest.AnActionMissingItsPortIsRejectedRatherThanDefaultingToZero, LLMResponseParsingTest.ARerouteWithANonStringHopIsRejectedRatherThanPartiallyParsed, LLMResponseParsingTest.AKGivenAsAStringIsRejectedRatherThanParsedOutOfTheText, LLMResponseParsingTest.OneUnparseableTaskRejectsTheWholeReplyRatherThanPartOfIt -->
| `TheThreeDocumentedLockNamesAreValidAndNothingElseIs` | `include/ndt_core/lock_management/LockManager.hpp:40` | `str == "graph_lock"` -> `str.find("graph") != npos` | `[  FAILED  ] LockManagerTest.TheThreeDocumentedLockNamesAreValidAndNothingElseIs (0 ms)` | <!-- sole failure -->
| `TheDefaultLockNameConstantIsOneTheManagerActuallyAccepts` | `include/ndt_core/lock_management/LockManager.hpp:27` | `DEFAULT_LOCK_TYPE_STR = "routing_lock"` -> `DEFAULT_LOCK_TYPE_STR = "routing"` | `[  FAILED  ] LockManagerTest.TheDefaultLockNameConstantIsOneTheManagerActuallyAccepts (0 ms)` | <!-- sole failure -->
| `AnUnknownLockNameIsRefusedRatherThanCreatingAFourthLock` | `include/ndt_core/lock_management/LockManager.hpp:65` | `if (type == LockType::Unknown) return false` -> `if (false) ... (unknown names accepted)` | `[  FAILED  ] LockManagerTest.AnUnknownLockNameIsRefusedRatherThanCreatingAFourthLock (0 ms)` | <!-- sole failure -->
| `ASecondAcquireOfAHeldLockIsRefused` | `include/ndt_core/lock_management/LockManager.hpp:77` | `if (state.isLocked && now < state.expiryTime) return false` -> `if (false) ... (never refuses)` | `[  FAILED  ] LockManagerTest.ASecondAcquireOfAHeldLockIsRefused (0 ms)` (+5 others) | <!-- also broke 5 other test(s): LockManagerTest.TheThreeLocksAreIndependentOfEachOther, LockManagerTest.UnlockingAnUnknownNameDoesNotReleaseARealLock, LockManagerTest.APositiveTtlStillHoldsTheLockWhileItHasTimeLeft, LockManagerTest.RenewingAnExpiredLockPutsItBackInForce, LockManagerTest.ExactlyOneOfManyConcurrentAcquiresWins -->
| `TheThreeLocksAreIndependentOfEachOther` | `include/ndt_core/lock_management/LockManager.hpp:73` | `m_locks[type]` -> `m_locks[LockType::Routing]` | `[  FAILED  ] LockManagerTest.TheThreeLocksAreIndependentOfEachOther (0 ms)` (+3 others) | <!-- also broke 3 other test(s): LockManagerTest.UnlockingMakesTheLockAvailableAgain, LockManagerTest.RenewingALockNobodyHoldsIsRefused, LockManagerTest.RenewingOneLockDoesNotExtendAnother -->
| `UnlockingMakesTheLockAvailableAgain` | `include/ndt_core/lock_management/LockManager.hpp:98` | `isLocked = false` -> `isLocked = true` | `[  FAILED  ] LockManagerTest.UnlockingMakesTheLockAvailableAgain (0 ms)` (+3 others) | <!-- also broke 3 other test(s): LockManagerTest.TheThreeLocksAreIndependentOfEachOther, LockManagerTest.UnlockingIsIdempotentAndSafeOnALockNobodyEverTook, LockManagerTest.RenewingALockNobodyHoldsIsRefused -->
| `UnlockingAnUnknownNameDoesNotReleaseARealLock` | `include/ndt_core/lock_management/LockManager.hpp:94` | `if (Unknown) return;` -> `if (Unknown) type = Routing;` | `[  FAILED  ] LockManagerTest.UnlockingAnUnknownNameDoesNotReleaseARealLock (0 ms)` | <!-- sole failure -->
| `AZeroTtlLockIsAlreadyExpiredWhenTheNextCallerAsks` | `include/ndt_core/lock_management/LockManager.hpp:77` | `now < state.expiryTime` -> `now <= state.expiryTime` | **NO-FAILURE** | <!-- needs another mutation or deletion -->
| `ANegativeTtlIsTreatedAsAlreadyExpiredRatherThanAsForever` | `include/ndt_core/lock_management/LockManager.hpp:84` | `seconds(ttlSeconds)` -> `seconds((unsigned)ttlSeconds)` | `[  FAILED  ] LockManagerTest.ANegativeTtlIsTreatedAsAlreadyExpiredRatherThanAsForever (0 ms)` | <!-- sole failure -->
| `APositiveTtlStillHoldsTheLockWhileItHasTimeLeft` | `include/ndt_core/lock_management/LockManager.hpp:84` | `expiryTime = now + seconds(ttl)` -> `expiryTime = now` | `[  FAILED  ] LockManagerTest.APositiveTtlStillHoldsTheLockWhileItHasTimeLeft (0 ms)` (+4 others) | <!-- also broke 4 other test(s): LockManagerTest.ASecondAcquireOfAHeldLockIsRefused, LockManagerTest.TheThreeLocksAreIndependentOfEachOther, LockManagerTest.UnlockingAnUnknownNameDoesNotReleaseARealLock, LockManagerTest.ExactlyOneOfManyConcurrentAcquiresWins -->
| `RenewingAnExpiredLockPutsItBackInForce` | `include/ndt_core/lock_management/LockManager.hpp:118` | `expiryTime = now + seconds(ttl)` -> `expiryTime = now` | `[  FAILED  ] LockManagerTest.RenewingAnExpiredLockPutsItBackInForce (0 ms)` | <!-- sole failure -->
| `RenewingALockNobodyHoldsIsRefused` | `include/ndt_core/lock_management/LockManager.hpp:?` | `if (!found || !isLocked) return false` -> `if (false) ... (renew always succeeds)` | **abort-anchor** | <!-- needs another mutation or deletion -->
| `RenewingOneLockDoesNotExtendAnother` | `include/ndt_core/lock_management/LockManager.hpp:118` | `m_locks[type].expiryTime = ...` -> `for (auto& kv : m_locks) kv.second.expiryTime = ...` | `[  FAILED  ] LockManagerTest.RenewingOneLockDoesNotExtendAnother (0 ms)` | <!-- sole failure -->
| `ExactlyOneOfManyConcurrentAcquiresWins` | `include/ndt_core/lock_management/LockManager.hpp:70` | `std::lock_guard<std::mutex> lock(m_mutex);` -> `(lock_guard removed)` | `[  FAILED  ] LockManagerTest.ExactlyOneOfManyConcurrentAcquiresWins (0 ms)` | <!-- sole failure -->
| `UnlockingIsIdempotentAndSafeOnALockNobodyEverTook` | `include/ndt_core/lock_management/LockManager.hpp:97` | `if (found) isLocked = false` -> `if (!found) throw; isLocked = false` | `[  FAILED  ] LockManagerTest.UnlockingIsIdempotentAndSafeOnALockNobodyEverTook (0 ms)` | <!-- sole failure -->
| `TheStringOutputFormYieldsThePortItNames` | `src/ndt_core/collection/Classifier.cpp:904` | `outputPorts.push_back(port)` -> `outputPorts.push_back(port + 1)` | `[  FAILED  ] ClassifierActionFormsTest.TheStringOutputFormYieldsThePortItNames (0 ms)` (+13 others) | <!-- also broke 13 other test(s): ClassifierDropRule.TheHighestPriorityRuleStillWinsAcrossSubtables, ClassifierDropRule.ANormalRuleStillReportsItsOutputPort, P4FlowStatsToClassifier.TheHigherPriorityFiveTupleRuleWins, P4FlowStatsToClassifier.TrafficNotCoveredByTheFiveTupleRuleFallsBackToTheLpmRoute, ClassifierActionFormsTest.TheActionKindIsMatchedCaseInsensitivelyButThePortIsNot, ClassifierActionFormsTest.SeveralOutputActionsAllArriveInTheOrderTheyWereListed, ClassifierActionFormsTest.AGotoTableInstructionIsPickedUpFromTheInstructionsArray, ClassifierActionFormsTest.ActionsNestedInsideAnInstructionAreAlsoParsed -->
| `TheActionKindIsMatchedCaseInsensitivelyButThePortIsNot` | `src/ndt_core/collection/Classifier.cpp:860` | `kind = toUpper(kind)` -> `kind = kind (no uppercasing)` | `[  FAILED  ] ClassifierActionFormsTest.TheActionKindIsMatchedCaseInsensitivelyButThePortIsNot (0 ms)` | <!-- sole failure -->
| `SeveralOutputActionsAllArriveInTheOrderTheyWereListed` | `src/ndt_core/collection/Classifier.cpp:904` | `outputPorts.push_back(port)` -> `outputPorts.insert(begin(), port)` | `[  FAILED  ] ClassifierActionFormsTest.SeveralOutputActionsAllArriveInTheOrderTheyWereListed (0 ms)` | <!-- sole failure -->
| `AGroupActionIsRecordedSeparatelyFromOutputPorts` | `src/ndt_core/collection/Classifier.cpp:909` | `effect.groupId = gid` -> `effect.outputPorts.push_back(gid)` | `[  FAILED  ] ClassifierActionFormsTest.AGroupActionIsRecordedSeparatelyFromOutputPorts (0 ms)` | <!-- sole failure -->
| `AnUnparseableGroupIdLeavesTheGroupUnsetRatherThanZero` | `src/ndt_core/collection/Classifier.cpp:909` | `if (parseUint(rest, gid)) groupId = gid` -> `parseUint(rest, gid); groupId = gid` | `[  FAILED  ] ClassifierActionFormsTest.AnUnparseableGroupIdLeavesTheGroupUnsetRatherThanZero (0 ms)` | <!-- sole failure -->
| `AGotoTableInstructionIsPickedUpFromTheInstructionsArray` | `src/ndt_core/collection/Classifier.cpp:943` | `gotoTable = parseU64(table_id)` -> `gotoTable = parseU64(table_id) + 1` | `[  FAILED  ] ClassifierActionFormsTest.AGotoTableInstructionIsPickedUpFromTheInstructionsArray (0 ms)` | <!-- sole failure -->
| `ActionsNestedInsideAnInstructionAreAlsoParsed` | `src/ndt_core/collection/Classifier.cpp:?` | `if (ins.contains("actions"))` -> `if (false) (nested actions ignored)` | **abort-scope** | <!-- needs another mutation or deletion -->
| `TheObjectActionFormIsIgnoredEntirelyDocumentsCurrentBehaviour` | `src/ndt_core/collection/Classifier.cpp:853` | `(object actions ignored)` -> `object {"type","port"} form also parsed` | `[  FAILED  ] ClassifierActionFormsTest.TheObjectActionFormIsIgnoredEntirelyDocumentsCurrentBehaviour (0 ms)` (+1 others) | <!-- also broke 1 other test(s): P4FlowStatsToClassifier.AnObjectFormActionWouldNotHaveWorked -->
| `AnObjectGroupActionIsIgnoredTheSameWay` | `src/ndt_core/collection/Classifier.cpp:853` | `(object group actions ignored)` -> `object {"group_id"} form also parsed` | `[  FAILED  ] ClassifierActionFormsTest.AnObjectGroupActionIsIgnoredTheSameWay (0 ms)` | <!-- sole failure -->
| `AnActionsValueThatIsNotAnArrayIsIgnoredWithoutThrowing` | `src/ndt_core/collection/Classifier.cpp:846` | `if (!actions.is_array()) return;` -> `if (!actions.is_array()) throw;` | `[  FAILED  ] ClassifierActionFormsTest.AnActionsValueThatIsNotAnArrayIsIgnoredWithoutThrowing (0 ms)` | <!-- sole failure -->
| `AnActionKindTheParserDoesNotKnowIsSkippedButOthersStillApply` | `src/ndt_core/collection/Classifier.cpp:862` | `if (kind == "OUTPUT" && !rest.empty())` -> `... && s == actions[0] (only a leading OUTPUT counts)` | `[  FAILED  ] ClassifierActionFormsTest.AnActionKindTheParserDoesNotKnowIsSkippedButOthersStillApply (0 ms)` (+1 others) | <!-- also broke 1 other test(s): ClassifierActionFormsTest.SeveralOutputActionsAllArriveInTheOrderTheyWereListed -->
| `AnOutputWithNoTargetIsSkippedRatherThanBecomingPortZero` | `src/ndt_core/collection/Classifier.cpp:898` | `if (!parseUint(...)) continue;` -> `if (!parseUint(...)) port = 0;` | `[  FAILED  ] ClassifierActionFormsTest.AnOutputWithNoTargetIsSkippedRatherThanBecomingPortZero (0 ms)` (+2 others) | <!-- also broke 2 other test(s): ClassifierActionFormsTest.LeadingWhitespaceAndAPlusSignAreAcceptedInAPortNumber, ClassifierActionFormsTest.AnOutputPortTooLargeForThirtyTwoBitsIsRefusedNotTruncated -->
| `LeadingWhitespaceAndAPlusSignAreAcceptedInAPortNumber` | `src/ndt_core/collection/Classifier.cpp:803` | `(strtoul tolerates leading space and +)` -> `reject unless s[0] is a digit` | `[  FAILED  ] ClassifierActionFormsTest.LeadingWhitespaceAndAPlusSignAreAcceptedInAPortNumber (0 ms)` | <!-- sole failure -->
| `AnOutputPortTooLargeForThirtyTwoBitsIsRefusedNotTruncated` | `src/ndt_core/collection/Classifier.cpp:?` | `if (v > 0xFFFFFFFF) return false` -> `if (false) ... (truncates instead)` | **abort-scope** | <!-- needs another mutation or deletion -->
| `AllFourReservedOutputTargetsCollapseToOneValueDocumentsCurrentBehaviour` | `src/ndt_core/collection/Classifier.cpp:876` | `OFPP_LOCAL = 65535` -> `OFPP_LOCAL = 65534 (the correct value)` | `[  FAILED  ] ClassifierActionFormsTest.AllFourReservedOutputTargetsCollapseToOneValueDocumentsCurrentBehaviour (0 ms)` | <!-- sole failure -->
| `AReservedTargetWithATrailingPortNumberUsesTheReservedValue` | `src/ndt_core/collection/Classifier.cpp:871` | `rest.substr(0, colon2)` -> `rest.substr(colon2 + 1)` | `[  FAILED  ] ClassifierActionFormsTest.AReservedTargetWithATrailingPortNumberUsesTheReservedValue (0 ms)` | <!-- sole failure -->
| `APriorityAboveSixteenBitsWrapsDocumentsCurrentBehaviour` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:642` | `(priority > 65535 wraps silently)` -> `if (priority > 65535) throw` | `[  FAILED  ] LLMResponseParsingTest.APriorityAboveSixteenBitsWrapsDocumentsCurrentBehaviour (0 ms)` | <!-- sole failure -->

---

# Review of this table (done separately from the agent that produced it)

## Format shortfall: the rows are descriptions, not replayable patches

The brief asked for literal `old text -> new text`. Several rows record the *sense* of the edit
instead: `actions[0].at("port")` where the line actually reads
`j.at("parameters").at("actions")[0].at("port")`, and one row's "old" is prose --
`(strtoul tolerates leading space and +)`. So an automated replay of the table fails on those rows
with an anchor miss, and every row had to be reconstructed by hand to re-check it. Not fabrication,
but it costs the table its main long-term value. **Anything added here later must be
copy-paste-applicable.**

## Three rows re-verified by hand, sampled across all three files

| row | claim | re-verified result |
|---|---|---|
| `OnlyTheFirstActionIsReadAndTheRestAreSilentlyIgnored` | sole failure | killed, sole failure |
| `AnOutputWithNoTargetIsSkippedRatherThanBecomingPortZero` | + 2 named others | killed, **exactly those 2 others**, names matched |
| `AnUnknownLockNameIsRefusedRatherThanCreatingAFourthLock` | sole failure | killed, sole failure |

The middle row is the strongest evidence the table is real: it predicted the blast radius by name
and the prediction held.

## The five NO-FAILURE rows, now resolved

The agent flagged five of its own tests as unkilled rather than quietly shipping them. All five are
now settled, and four needed a **two-site** mutation because the property is enforced twice --
the same shape three times over in this file, which is the finding worth carrying:

| test | why the single-site mutation survived | mutation that kills it |
|---|---|---|
| `ANegativeOrderWrapsToItsUnsignedValueDocumentsCurrentBehaviour` | narrowing happens twice: `get<uint16_t>()` on read **and** the `uint16_t` field on assignment, so widening either alone leaves the other doing it | widen both: `LLMResponseTypes.hpp:471` `uint16_t order;` -> `int32_t order;` **and** `:488` `get<uint16_t>()` -> `get<int32_t>()` |
| `APriorityAboveSixteenBitsWrapsDocumentsCurrentBehaviour` | same, on `InstallFlowEntryTask` | `:611` + `:642`, same pair of edits |
| `AZeroTtlLockIsAlreadyExpiredWhenTheNextCallerAsks` | the agent mutated the comparison `now < expiryTime`, which is timing-dependent and can survive | `LockManager.hpp:84` `std::chrono::seconds(ttlSeconds)` -> `std::chrono::seconds(ttlSeconds + 60)` -- deterministic |
| `ATasksEntryThatIsNotATaskObjectIsRejected` | mutating `taskTypeFromString` still threw for other reasons | `LLMResponseTypes.hpp:2344` `if (ans.valid)` -> `if (false)` |
| `AReplyWithNoStateIsRejectedRatherThanAssumedToBeAnAnswer` | **the test was over-determined** -- see below | test strengthened, then `:462` + `:2443` both switched from `j.at("state")` to `j.value("state", "answer")` |

### The last one was a weak test, not just a missing mutation

All four of its original inputs were missing `explanation` as well as `state`, and
`from_json(Answer&)` reads `explanation` at `:2342`, before anything consults `state`. So the throws
it observed had nothing to do with the property in its name: remove the state requirement entirely
and it still passes. A discriminating case was added -- `{"explanation": "", "valid": false}`,
complete except for `state`, with `valid` false so the tasks array is not required either. That
assertion is the only one in the test that fails when a missing state stops being refused, and it is
the one that fired.

Running total of tests that mutation has shown to prove nothing on this repo: **11** (7 earlier, 2
of mine in `test_HttpSessionRouting.cpp`, this one, and one of the agent's own that it caught).

## Verified state at review time

350 tests, green under `ctest` and under `./build/bin/test_routing_strategy` run directly, zero
skipped, `ctest -N` count == `--gtest_list_tests` count, zero build warnings, and `git status` clean
across `src/` and `include/` -- no mutation left behind.

---

# Appendix: replayable literal patches (verified 2026-08-07)

The rows in the main table record mutations as *descriptions*, which cannot be applied
mechanically. Below are those same mutations rewritten as literal `OLD` -> `NEW` edits at the stated
line, and **none of them is taken on trust**: every entry was applied, built, run, observed to fail
its named test, and then restored byte-exactly. Apply with a single-occurrence string replace on
that line.

Two rows name the same test twice where the agent recorded two independent mutations for it; both
were verified.

| test | file:line | OLD (literal) | NEW (literal) |
|---|---|---|---|
| `AnUnmappedTaskTypeIsNamedRatherThanRenderedAsAnInteger` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:227` | `Unknown` | `unmapped` |
| `AnUnmappedTaskTypeIsNamedRatherThanRenderedAsAnInteger` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:227` | `Unknown` | `unmapped` |
| `AnUnknownTaskNameIsRejectedRatherThanDefaultingToATask` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:441` | `throw std::runtime_error("unknown task type: " + std::string{s});` | `return DISABLE_SWITCH;` |
| `DeserialisingTwiceIntoTheSameAnswerAppendsDocumentsCurrentBehaviour` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:2346` | `for` | `ans.tasks.clear(); for` |
| `SeveralTasksArriveInTheOrderTheyWereListed` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:2350` | `push_back(` | `insert(ans.tasks.begin(),` |
| `ATaskThatTakesNoParametersDoesNotRequireAParametersObject` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:821` | `task_from_json(j, task);` | `j.at("parameters");` |
| `AnInstallFlowEntryCarriesItsDeviceMatchPriorityAndAction` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:641` | `j.at("parameters").at("device_name").get<std::string>()` | `""` |
| `AnEmptyActionsArrayMeansDropAndIsSignalledByPortMinusOne` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:652` | `-1` | `0` |
| `OnlyTheFirstActionIsReadAndTheRestAreSilentlyIgnored` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:647` | `[0]` | `.back()` |
| `TheStringActionFormRyuUsesIsRejectedHereDocumentsCurrentBehaviour` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:644` | `empty()` | `empty() && !j.at("parameters").at("actions")[0].is_string()` |
| `AnActionMissingItsPortIsRejectedRatherThanDefaultingToZero` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:647` | `.at("port")` | `.value("port", 0)` |
| `AMatchIsCarriedThroughVerbatimWithoutBeingValidated` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:742` | `j.at("parameters").at("match")` | `json::object()` |
| `AModifyFlowEntryTaskConstructsItselfAsAnInstallDocumentsCurrentBehaviour` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:664` | `INSTALL_FLOW_ENTRY` | `MODIFY_FLOW_ENTRY` |
| `ARerouteCarriesEveryHopInTheOrderTheModelGaveThem` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:1251` | `j.at("parameters").at("new_path").get<std::vector<std::string>>()` | `std::vector<std::string>(j.at("parameters").at("new_path").size())` |
| `AGroupEntrysBucketsAreCarriedThroughVerbatim` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:1472` | `j.at("parameters").at("buckets")` | `json::array()` |
| `AMeterEntrysFlagsListIsCarriedThroughInOrder` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:1507` | `j.at("parameters").at("flags").get<std::vector<std::string>>()` | `{}` |
| `AKGivenAsAStringIsRejectedRatherThanParsedOutOfTheText` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:771` | `.get<int>()` | `.is_string() ? std::stoi(j.at("parameters").at("k").get<std::string>()) : j.at("parameters").at("k").get<int>()` |
| `ANegativeKIsCarriedThroughForTheCallerToDealWith` | `include/ndt_core/intent_translator/LLMResponseTypes.hpp:771` | `j.at("parameters").at("k").get<int>()` | `std::max(0, j.at("parameters").at("k").get<int>())` |
| `AnUnknownLockNameIsRefusedRatherThanCreatingAFourthLock` | `include/ndt_core/lock_management/LockManager.hpp:65` | `type == LockType::Unknown` | `false` |
| `ASecondAcquireOfAHeldLockIsRefused` | `include/ndt_core/lock_management/LockManager.hpp:77` | `state.isLocked && now < state.expiryTime` | `false` |
| `UnlockingAnUnknownNameDoesNotReleaseARealLock` | `include/ndt_core/lock_management/LockManager.hpp:94` | `return;` | `type = LockType::Routing;` |
| `APositiveTtlStillHoldsTheLockWhileItHasTimeLeft` | `include/ndt_core/lock_management/LockManager.hpp:84` | `now + std::chrono::seconds(ttlSeconds)` | `now` |
| `RenewingAnExpiredLockPutsItBackInForce` | `include/ndt_core/lock_management/LockManager.hpp:118` | `std::chrono::steady_clock::now() + std::chrono::seconds(ttlSeconds)` | `std::chrono::steady_clock::now()` |
| `RenewingOneLockDoesNotExtendAnother` | `include/ndt_core/lock_management/LockManager.hpp:118` | `m_locks[type].expiryTime` | `for (auto& kv : m_locks) kv.second.expiryTime` |
| `AnUnparseableGroupIdLeavesTheGroupUnsetRatherThanZero` | `src/ndt_core/collection/Classifier.cpp:909` | `if (parseUint(rest, gid))` | `parseUint(rest, gid);` |
| `AGotoTableInstructionIsPickedUpFromTheInstructionsArray` | `src/ndt_core/collection/Classifier.cpp:943` | `parseU64(ins.at("table_id"))` | `parseU64(ins.at("table_id")) + 1` |
| `TheObjectActionFormIsIgnoredEntirelyDocumentsCurrentBehaviour` | `src/ndt_core/collection/Classifier.cpp:853` | `a.is_string()` | `a.is_string() \|\| (a.is_object() && a.contains("type") && a.contains("port"))` |
| `AnObjectGroupActionIsIgnoredTheSameWay` | `src/ndt_core/collection/Classifier.cpp:853` | `a.is_string()` | `a.is_string() \|\| (a.is_object() && a.contains("group_id"))` |

## Four conversions that failed, and why that is informative

Of 40 rows needing conversion, 32 produced a valid unique substring and **28 of those survived the
build-and-run check**. The four that did not are all on the same handful of tests Agent A had
already flagged NO-FAILURE, and they failed for the structural reason documented above rather than
through carelessness:

| row | test | outcome | cause |
|---|---|---|---|
| 4 | `AReplyWithNoStateIsRejected…` | SURVIVED | mutates only `:2443`; `:462` still throws. This *is* the double-enforcement finding |
| 23 | `AReplyWithNoStateIsRejected…` | NO-COMPILE | unqualified `make_unique` |
| 5 | `ANullTasksFieldYieldsNoTasks…` | NO-COMPILE | `array_t` is not a name in that scope |
| 7 | `ATasksEntryThatIsNotATaskObjectIsRejected` | SURVIVED | guard added at the wrong level |

Rows 4, 7 and 23 are superseded by the hand-built mutations in the NO-FAILURE table above, which do
kill those tests.

## How this conversion was produced, and what it says about the tool

The literal edits were generated by `deepseek-cli` (deepseek-v4-flash, reasoning_effort=max) from
the prose rows plus the actual line text, then verified here. Scorecard worth keeping:

- **Extraction: reliable.** 32/40 correct *unique* substrings, **zero hallucinated**, and **8 rows
  declared `IMPOSSIBLE`** rather than guessed. The prompt explicitly offered that escape hatch and
  said an honest refusal beats a guess; that is what produced the refusals.
- **Judging its own output: not reliable.** 4 of 32 were wrong in ways only a compiler or a test
  run could reveal, despite the prompt requiring valid C++. Two did not even compile.

So the division of labour is: **the model extracts, the toolchain adjudicates.** A cheap check
(string match) first, then the expensive one (build + run) on everything you intend to rely on.
Substring-validity alone would have shipped 4 bad rows.

---

# Appendix 2: FlowStatsTimeoutTest (10 tests, verified 2026-08-07)

Guards the fix for the Ryu wedge -- refusing an empty flow table that arrived at Ryu's stats
timeout. Every row applied, built, run, observed, restored. Anchors are literal and
single-occurrence, so each is replayable with a plain string replace on that line.

| # | mutation | file | kills |
|---|---|---|---|
| M1 | `kFlowStatsSuspectSeconds = 0.5;` -> `= 0.02;` | `…/DeviceConfigurationAndPowerManager.hpp` | **5** — every "a healthy round trip must still be believed" test |
| M2 | `kFlowStatsSuspectSeconds = 0.5;` -> `= 1.5;` | same | **6** — every "a wedged round trip must be refused" test |
| M3b | `if (entry.value().is_array() && …)` -> `if (entry.key() == "0" && entry.value().is_array() && …)` | `…PowerManager.cpp` | 1 — `EntriesInAnyTableCountNotJustTheFirst` |
| M4 | `elapsedSeconds >= kFlowStatsSuspectSeconds` -> `>` | same | 1 — `TheThresholdIsInclusive…` |
| M5 | `else if (flows.is_array() && !flows.empty())` -> `else if (false)` | same | 1 — `TheP4ProxyArrayShapeIsHandledToo` |
| M6b | inner `return FlowStatsVerdict::Usable;` (16-space indent) -> latency-conditional | same | 2 — `ATableWithEntriesIsAlwaysBelievedNoMatterHowSlow`, `EntriesInAnyTableCountNotJustTheFirst` |

M1 and M2 are deliberately kept as a pair: they kill **disjoint** sets from opposite sides, so the
threshold is pinned from below *and* above. A single mutation could not establish that.

## Two mutations that failed, and what they cost

- **M3 (`if (false)`) did not compile** -- `-Werror` on the now-unused loop variable. A mutation that
  does not build is not evidence either way; replaced with M3b, which is also narrower.
- **M6 survived, and that was my error rather than a surviving test.** I inserted the latency check
  *after* the early `return Usable`, where a non-empty table can never reach it -- dead code, so of
  course nothing failed. The lesson is the one already recorded twice in this file: confirm the
  mutation is on the path the test exercises, not merely present in the file. M6b moves the check
  onto the early return and kills 2 tests.

## Process note: I nearly destroyed this work verifying it

The first attempt at this table used `git checkout -- <file>` to revert each mutation while the
feature was still **uncommitted**, so the first revert discarded the entire change -- header, source
and all. It was reconstructed from scratch. `git checkout` is only a safe revert once the work is
committed; before that, copy the file aside. This is the same hazard handled correctly two hours
earlier for `test_HttpSessionRouting.cpp` with a scratchpad copy, and then not carried across.

**Commit the feature first, then mutate.** That is now the order followed here.

---

# Appendix 3: CounterDeltaTest (6 tests, verified 2026-08-07)

Guards `sflow::counterDelta`, which stops a counter that went backwards being reported as ~1.8e19
bits per second. All anchors literal and single-occurrence in `include/common_types/SFlowType.hpp`.

| # | mutation | kills |
|---|---|---|
| M1 | `return (current >= previous) ? (current - previous) : 0;` -> `return current - previous;` (the bug restored) | 3 — `ACounterThatWentBackwardsYieldsZeroRatherThanWrappingTo18Exa`, `TheWrappedValueWouldHaveBeenReportedAsAnElephantFlow`, `ARealCounterResetToZeroIsTheCommonBackwardsCase` |
| M2 | saturate the wrong way: `(current <= previous) ? (previous - current) : 0` | 5 |
| M3 | off-by-one: `(current - previous + 1)` | 3 — `TheOrdinaryForwardCaseIsPlainSubtraction`, `NoTrafficSinceTheLastReadingIsZeroNotAnError`, `LargeForwardDeltasAreNotClamped` |

M3 exists because M1 and M2 between them left `NoTrafficSinceTheLastReadingIsZeroNotAnError`
unproven -- `x - x` is zero under both of those, so neither could break it. An off-by-one is the
realistic bug shape for that assertion, and it kills it. Worth noting as a pattern: a test asserting
a value that arithmetic almost forces needs a mutation aimed at *it*, not at the interesting
behaviour nearby.

Not covered, and stated in the commit: that the two call sites use the helper. Both are inside
`calAvgFlowSendingRatesPeriodically`, which runs on a thread started by `start()`, so restoring the
bare subtraction *there* would go unnoticed.

---

# Appendix 4: the empty-path guard in setAllPaths (3 tests, verified 2026-08-07)

Found by agy-review 0110 and verified before fixing. Anchors in
`src/ndt_core/collection/FlowLinkUsageCollector.cpp`.

| # | mutation | result |
|---|---|---|
| M1 | `if (path.empty())` -> `if (false)` (the guard removed) | **all 3 tests killed by SIGSEGV**, rc=139, no gtest summary |
| M2 | the guard's `continue;` -> `return;` (reject the snapshot instead of skipping the path) | 2 killed — `TheUsablePathsInAMixedSnapshotAreStillStored`, `AnEmptyPathDoesNotPreventTheReplacementOfEarlierData` |

M1 killing by crash rather than by assertion is the honest manifestation: `front()` on an empty
container is undefined behaviour, so there is nothing for an assertion to compare. It is stronger
evidence than a failed expectation, not weaker.

## A harness bug this exposed

The first M1 run reported nothing at all — no failures, no pass count — and read as "the mutation
survived". It had not: the binary segfaulted before gtest could print a summary, and the driver only
grepped for `[  FAILED  ]` lines and the summary line, both of which a crash omits. The driver now
reports a missing summary as `KILLED BY CRASH (rc=…)`.

Third time in this file that the *measurement* was wrong rather than the code: after "confirm the
mutation landed on the path the test exercises" and "a dead-code insertion is not a mutation", add
**"absence of a failure line is not evidence of survival — check the exit code."**

---

# Appendix 5: TryMacToUint64Test (7 tests, verified 2026-08-07)

Anchors in `include/utils/Utils.hpp`. Found by agy-review 0115.

| # | mutation | kills |
|---|---|---|
| M1b | `mac.size() != kMacTextLength` -> `<` (over-long strings get truncated-parsed) | 1 — `AnythingThatIsNotExactlySeventeenCharactersIsRefused` |
| M2 | drop `end != mac.data() + at + 2` (the consumed-both-digits check) | 1 — `NonHexDigitsAreRefused` |
| M3 | drop the separator check | 1 — `TheSeparatorsMustActuallyBeSeparators` |
| M4 | stop accepting `-` as a separator | 1 — `TheDashSeparatorIsAcceptedToo` |
| M5 | `result = (result << 8) \| byte` -> `result = byte` | 3 |
| M6 | the throwing wrapper returns 0 instead of throwing | 1 — `TheThrowingWrapperStillThrowsAndOnTheSameInputs` |
| M7 | **two-site**: `kMacTextLength` 17 -> 16 **and** drop the consumed-digits check | 4, including `AMacOneDigitShortIsRefusedRatherThanSilentlyWrong` |

## Two things worth carrying forward

**M1 did not compile.** Replacing the length test with `if (false)` left `kMacTextLength` unused and
`-Werror` rejected it. A mutation that does not build is not evidence either way; M1b keeps the
constant used and is narrower besides.

**M7 is the third instance of double enforcement in this repo.** The one-digit-short input is refused
by the length check *and* by the consumed-digits check independently, so no single-site mutation can
reach the test that asserts it — exactly as with `order`/`priority` (narrowing at both the
`get<uint16_t>()` and the field type) and with the missing `state` (enforced at both the dispatch and
the assignment). Two independent checks refusing the same bad input is good defence; it just means
the test needs a mutation aimed at both, and a surviving single-site mutation there is a fact about
the code's redundancy rather than about the test's weakness.

---

# Appendix 6: the head-of-line fix (7 mutants, verified 2026-08-13)

Covers `1a7d815` "Stop one stalled switch from taking the whole proxy down". Both languages, because
the fix spans both: the proxy stopped running blocking gRPC on its event loop, and the kernel stopped
issuing an unbounded `curl`.

`observed failure` is copied from stdout, per this file's opening rule. Python runs used
`PYTHONDONTWRITEBYTECODE=1`; the harness also refuses to start unless the two production files are
committed, because its restore step is `git checkout --`.

| test | mutation file:line | old -> new | observed failure |
|---|---|---|---|
| `ReadDeadlineTest` (3 tests) | `p4_proxy/proxy_agent/p4_client.py:442` | `self.stub.Read(req, timeout=timeout_s)` -> `self.stub.Read(req)` | `FAILED (failures=2, errors=1)` |
| `BlockingWorkStaysOffTheEventLoopTest` + route tests | `p4_proxy/proxy_agent/api_routes.py:248` | `def get_flow_stats(dpid: int):` -> `async def get_flow_stats(dpid: int):` | `FAILED (failures=5, errors=3)` — 8 of the file's 9 tests |
| `test_a_flow_entry_write_runs_on_a_worker_thread` | `p4_proxy/proxy_agent/api_routes.py:139` | `await run_in_threadpool(topology.route_flow, dpid, match, actions)` -> `topology.route_flow(dpid, match, actions)` | `FAILED (failures=1)` |
| same | `p4_proxy/proxy_agent/api_routes.py:157` | `await run_in_threadpool(topology.unroute_flow, dpid, match)` -> `topology.unroute_flow(dpid, match)` | `FAILED (failures=1)` |
| same | `p4_proxy/proxy_agent/api_routes.py:179` | `await run_in_threadpool(topology.modify_flow, dpid, match, actions)` -> `topology.modify_flow(dpid, match, actions)` | `FAILED (failures=1)` |
| `RequestDeadlines.TheFlowTableRequestIsBounded` | `src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp:848` | `"curl -s --max-time 8 -X GET ..."` -> `"curl -s -X GET ..."` | `[  FAILED  ] RequestDeadlines.TheFlowTableRequestIsBounded` (+1: `TheFlowTableDeadlineOutlivesTheProxysOwnGrpcDeadline`) |
| `RequestDeadlines.TheLivenessRequestIsBounded` | `src/ndt_core/power_management/DeviceConfigurationAndPowerManager.cpp:835` | `"curl -s --max-time 3 -w ..."` -> `"curl -s -w ..."` | `[  FAILED  ] RequestDeadlines.TheLivenessRequestIsBounded` (sole failure) |

**7 applied, 7 killed, 0 survived.**

## Correction: `1a7d815`'s own commit message states these as predictions

The "Mutation evidence" paragraph in `1a7d815` was written **before the harness was run**. It is
substantively right — every mutant did die — but two details are wrong, and the message does not say
it was predicting:

- it claims the `async def` mutant fails "BlockingWorkStaysOffTheEventLoopTest and four of the
  existing route tests". The measured result is 8 of 9 tests in that file. Understated.
- it omits the two C++ mutants entirely; they had not been run when it was written.

Not amended, because `1a7d815` was already pushed by the time this was noticed (carried up by a
concurrent session's push of the branch, not pushed deliberately). Rewriting published history to
hide the slip would also destroy the more useful record: this file's opening line says observed
failure text is "never predicted", and the violation was writing the conclusion into a durable
artefact before running the thing that would have produced it. The gate caught it in the sense that
running the harness immediately afterwards is what exposed the discrepancy — but the message had
already been committed by then, which is the actual process defect.

## Harness note carried over from a same-day incident

`PYTHONDONTWRITEBYTECODE=1` alone is **not** sufficient — pre-existing `__pycache__` must also be
cleared. A mutant that preserves byte length (e.g. `"<I"` -> `"!I"`) passes the pyc `(mtime, size)`
validation and therefore never executes, which is indistinguishable from a weak test. Another agent
reported three false survivors this way on 2026-08-13. The seven mutants above all changed length, so
this run was not affected, but the harness should clear the caches rather than rely on that.
