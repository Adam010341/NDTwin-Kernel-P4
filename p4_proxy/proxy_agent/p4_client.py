import logging
import threading
import queue
import time
import grpc
import socket
from p4.v1 import p4runtime_pb2
from p4.v1 import p4runtime_pb2_grpc
from p4.config.v1 import p4info_pb2
from google.protobuf import text_format

from proxy_agent import boot_identity
from proxy_agent.rule_install_times import RuleInstallTimes
from proxy_agent.sflow_emitter import PKTIN_META_INGRESS_PORT, sample_from_packet_in


# [Co-developed with claude code -- Adam]
# Every unary gRPC call carries this. Without it a Write to a switch whose channel has gone away
# blocks forever -- and these are reached from the stream-receive thread: handle_packet_in ->
# install_initial_routes -> insert_ipv4_route, so one dead switch stalled packet-in handling for
# every live switch. gRPC's default is no deadline at all, which is the wrong default for a proxy
# that must keep serving the switches still up.
#
# 5 s rather than tighter: bmv2 table writes are not fast under load, and a spurious
# DEADLINE_EXCEEDED would report a rule that did land as a failed install.
RPC_TIMEOUT_S = 5.0

# [Co-developed with claude code -- Adam]
#
# Must match ndtwin_switch.p4. SAMPLE_SESSION is the clone session the pipeline clones telemetry
# samples to; nothing arrives until it is programmed, because a clone to an unconfigured session
# is silently dropped by bmv2.
SAMPLE_SESSION_ID = 250
CPU_PORT = 255


#: The election id every client bid before app packages existed, and the one a fabric with no
#: package still bids. `high` is 0 and `low` is 1, which is what `req.election_id.low = 1` on
#: each unary request used to say inline. [Co-developed with claude code -- Adam]
DEFAULT_ELECTION_ID = (0, 1)


class ControlPlaneReadOnly(RuntimeError):
    """
    A write was attempted against a switch whose control plane belongs to somebody else.

    [Co-developed with claude code -- Adam]
    Raised, never returned as False, and deliberately not a subclass of anything the write paths
    already catch. `insert_ipv4_route` and friends answer False for "the switch refused this",
    and the callers treat that as a transient condition to be retried on the next watchdog pass.
    This is not that: an `external` fabric will refuse every write for as long as it runs, and a
    retry loop quietly spinning on it is how "the exercise's controller was fighting the proxy"
    would get discovered from a packet capture instead of from a message.

    RuntimeError rather than a new root so an `except Exception` in a background loop still
    contains it -- what must not happen is a bare `except grpc.RpcError` swallowing it as a
    switch-side failure.
    """


class CounterNotFound(LookupError):
    """
    A counter was asked for by name and this pipeline's P4Info does not contain it.

    Separate from a read failure on purpose. This one cannot be retried and cannot be sampled
    around: the running pipeline does not have the counter, so any number returned would be
    invented. LookupError so an over-broad `except Exception` in a polling loop still catches it,
    but it can be caught specifically by anything that wants to tell the two apart.
    [Co-developed with claude code -- Adam]
    """


class P4RuntimeClient:
    """Encapsulates P4Runtime gRPC connection to a single BMv2 switch"""
    def __init__(self, device_id, grpc_addr, p4info_path, json_path=None,
                 election_id=DEFAULT_ELECTION_ID, arbitration=True):
        self.device_id = device_id
        self.grpc_addr = grpc_addr
        self.p4info = self._build_p4info(p4info_path)
        self.json_path = json_path

        # --- who this client claims to be. [Co-developed with claude code -- Adam]
        #
        # Was the literal `(0, 1)`, written out thirteen times: once in the arbitration message
        # and once per unary request as `req.election_id.low = 1`. One value in one place now,
        # and the default is that same (0, 1) so a fabric with no app package puts byte-identical
        # requests on the wire.
        #
        # 🔴 It is a parameter because of the mastership note below. A proxy that bids (0, 1) can
        # be impersonated by anything else that bids (0, 1) -- and P4Runtime says the LATER
        # equal bid wins the primary role, so the impostor's pipeline push is accepted and every
        # table is wiped. An app package bids higher (app_package.PACKAGE_DEFAULT_ELECTION_ID),
        # which turns that same push into PERMISSION_DENIED.
        self.election_id = (int(election_id[0]), int(election_id[1]))

        # --- whether this client drives the switch at all.
        #
        # False under an `external` app package: the exercise ships its own controller, that
        # controller holds mastership, and this object exists only to READ. It opens no
        # arbitration stream, starts no receiver thread, and raises ControlPlaneReadOnly from
        # every method that would write. Reads -- probe(), read_table_entries(),
        # read_egress_counter() -- need no election id and work unchanged.
        self.arbitration = bool(arbitration)

        # [Co-developed with claude code -- Adam]
        # True only while this stream holds P4Runtime mastership. Set from the arbitration
        # response, cleared whenever the stream ends. readopt_switch reads it before the
        # destructive pipeline push, and must: this flag being false does NOT stop the switch
        # from accepting our RPCs.
        #
        # Every client built with the DEFAULT election id (0, 1) bids the same number -- see
        # start() and the unary calls below. So a second such client raised against a switch the
        # first one still holds is not a lower-priority backup; it presents the incumbent's exact
        # (device_id, role, election_id). bmv2 terminates its *stream* as a duplicate, leaving
        # this flag false, but P4Runtime identifies the sender of a unary RPC by the 3-tuple in
        # the message rather than by the connection it arrived on, so the impostor's
        # SetForwardingPipelineConfig is accepted and wipes every table.
        #
        # That is what happened on 2026-08-13: readopt against a healthy switch wiped its
        # tables, installed nothing, and reported success. bmv2 was conforming throughout --
        # measured against a third-party client, a genuinely non-primary push is refused with
        # PERMISSION_DENIED. doc/2026-08-13_p4runtime-mastership-spec-check.md has the three
        # scenarios; p4_proxy/reference/p4runtime_mastership_probe.py re-runs them.
        #
        # 🔴 An app package bids higher than (0, 1) precisely so that an impostor presenting the
        # old default is refused with PERMISSION_DENIED instead of being accepted. And under
        # `arbitration=False` this flag stays False for the life of the client, which is the
        # honest answer: no stream was ever opened, so no mastership was ever claimed.
        self.mastership_confirmed = False

        # --- what this client has destroyed. [Co-developed with claude code -- Adam]
        #
        # KNOWN-ISSUES A-4c. `set_forwarding_pipeline_config` empties every table on this switch
        # (see the note above, and write_clone_session's docstring for the live measurement), and
        # until now that left no trace anywhere: bmv2 keeps running, the port stays open, and the
        # next poll reads a plausible table because install_initial_routes has refilled the
        # bring-up shortest paths. The rules that are actually gone are the ones installed since.
        #
        # `table_generation` is None until this client has committed a pipeline, and a fresh token
        # after each commit. None is not a token: a reader must be able to tell "this client has
        # never wiped this switch" from "it wiped it, and here is which wipe", or the first poll
        # after a start looks exactly like a wipe that already happened.
        #
        # Set only after the RPC returns, so a refused push -- the ordinary case when one bmv2 of
        # ten is down, which startup() catches per switch and continues past -- does not report a
        # wipe that did not occur.
        self.table_generation = None
        #: How many pipelines this client has committed. Diagnostic only; the comparison a reader
        #: makes is on the token, because this counter restarts at zero when readopt replaces the
        #: client object.
        self.pipeline_commits = 0

        # --- when this client wrote each rule. [Co-developed with claude code -- Adam]
        #
        # KNOWN-ISSUES G-13. A bmv2 table entry has no age, so /stats/flow/<dpid> reported
        # duration 0/0 for every rule and the P4 plane had no time axis at all -- measured
        # 2026-09-07 (W16-3). This is the only record of when a rule went on, and the write
        # methods below stamp it; ryu_flow_stats subtracts. See rule_install_times.py.
        #
        # Per client, not per process: readopt_switch replaces this object and pushes a pipeline
        # that empties the switch, so the replacement's empty record is the true one.
        self.rule_install_times = RuleInstallTimes()

        #: (row count, monotonic reading) of the most recent read_table_entries, or None when
        #: this client has never read its tables. The denominator for the record above:
        #: `rules_timed` alone cannot distinguish a switch this proxy installed nothing on from
        #: a switch with nothing on it. Assigned as ONE tuple so a reader on another thread can
        #: never see a count paired with somebody else's timestamp. See last_table_read().
        #: [Co-developed with claude code -- Adam]
        self._last_table_read = None


        # [Co-developed with claude code -- Adam]
        # This client owns its subchannel pool. grpc-python's default is a process-global pool
        # keyed by target address, so a brand-new channel to an address is handed whatever
        # subchannel a previous channel left there -- including that address's accumulated
        # reconnect backoff, which climbs toward gRPC's 120 s cap.
        #
        # That is what broke Phase 7 powerOn. While a bmv2 is down the liveness poller keeps
        # probing its old client every LIVENESS_PROBE_INTERVAL_S (2 s, topology_manager.py), so a
        # four-minute outage is ~120 failed connects on that address. readopt_switch then builds a
        # *fresh* client, which inherits the backoff and fails at step "pipeline" with
        # UNAVAILABLE ... Connection refused -- against a port that is listening and accepting TCP.
        # Live: down 1 s readopted first try, down 4 minutes did not. Nor does readopt release the
        # old channel first; old.stop() runs only after the new client has pushed its pipeline, and
        # on the failure path the old client is kept on purpose.
        #
        # Measured against grpc 1.82.1 -- hammer a closed port for 90 s, then start a real server
        # on it and time a fresh channel to READY. Same address, same process, same instant:
        #     with this option     0.00 s
        #     without it          32.56 s
        #
        # Nothing legitimate was being shared. Each switch has its own address
        # (localhost:30051..30060, main.build_p4_client), so there is normally exactly one live
        # client per address; the only sharing that ever occurred was between a dead client and
        # its replacement, which is precisely the bug. Note that gRPC ignores channel options it
        # does not recognise, so a typo here would be silent -- tests/test_p4_client_writes.py
        # pins the exact name.
        self.channel = grpc.insecure_channel(
            grpc_addr, options=[("grpc.use_local_subchannel_pool", 1)])
        self.stub = p4runtime_pb2_grpc.P4RuntimeStub(self.channel)
        
        self.stream_out_q = queue.Queue()
        self.stream_recv_thread = None
        self.is_running = False

        # Declared up front rather than probed with hasattr, so a missing assignment is a
        # None check rather than a silently skipped branch.
        self.packet_in_callback = None   # (device_id, ingress_port, payload) -> None
        self.sample_callback = None      # (device_id, SampledPacket) -> None

    # --- identity and permission. [Co-developed with claude code -- Adam] -------------------

    def _bid(self, message):
        """Stamp this client's election id onto a request. The one place that number is written.

        Returns the message so a caller can build and stamp in one expression. `high` is set
        explicitly rather than left at protobuf's zero default: an election id is a 128-bit
        number in two halves, and a client that only ever wrote the low half could never bid
        above 2**64 - 1 no matter what it was configured with.
        """
        message.election_id.high = self.election_id[0]
        message.election_id.low = self.election_id[1]
        return message

    def _refuse_write(self, what):
        """Raise unless this client is allowed to write to its switch.

        Called first in every method that puts an Update or a pipeline on the wire. `what` names
        the operation, because "read only" without the operation is not something an operator
        can act on.
        """
        if not self.arbitration:
            raise ControlPlaneReadOnly(
                f"switch {self.device_id} ({self.grpc_addr}): refusing {what} -- this fabric's "
                f"app package declares an external control plane, so the exercise's own "
                f"controller holds mastership and this proxy reads only")

    def _build_p4info(self, p4info_path):
        p4info = p4info_pb2.P4Info()
        with open(p4info_path, "r") as f:
            text_format.Merge(f.read(), p4info)
        return p4info

    def _stream_iterator(self):
        """Generator that reads from queue and yields StreamMessageRequest"""
        while self.is_running:
            try:
                # Block for a short time to allow checking is_running
                msg = self.stream_out_q.get(timeout=1.0)
                if msg is None:
                    break
                yield msg
            except queue.Empty:
                continue

    def _stream_receiver(self, stream):
        """Background thread to read StreamMessageResponse (e.g. Packet-In)"""
        try:
            for response in stream:
                if response.HasField("packet"):
                    self.handle_packet_in(response.packet)
                elif response.HasField("arbitration"):
                    # [Co-developed with claude code -- Adam]
                    # status.code 0 (OK) means this stream is the primary. A duplicate
                    # election id never even gets here -- bmv2 kills the stream, which lands
                    # in the except below -- so both refusal shapes leave the flag false.
                    self.mastership_confirmed = response.arbitration.status.code == 0
                    if self.mastership_confirmed:
                        print(f"[{self.device_id}] Received arbitration response: Mastership confirmed.")
                    else:
                        print(f"[{self.device_id}] Arbitration refused: status "
                              f"{response.arbitration.status.code} "
                              f"{response.arbitration.status.message!r}")
                else:
                    print(f"[{self.device_id}] Received unknown stream message.")
        except grpc.RpcError as e:
            if self.is_running:
                print(f"[{self.device_id}] Stream receiver error: {e.details()}")
        finally:
            # A stream that has ended holds no mastership, however it ended.
            self.mastership_confirmed = False

    def handle_packet_in(self, packet):
        """
        Routes a CPU packet to either the telemetry path or the discovery path.

        [Co-developed with claude code -- Adam]

        Telemetry samples and genuine packet-ins share this one channel, and are told apart by
        the `reason` field of packet_in_header_t rather than by inspecting the frame. They cannot
        be separate controller headers -- see the header comment in ndtwin_switch.p4.

        Sampled traffic is high-rate by design, so a sample must never reach the LLDP parser:
        that would try to read every sampled packet as a beacon and, at 1-in-256 of all traffic,
        drown discovery in work it cannot use.
        """
        sample = sample_from_packet_in(packet)
        if sample is not None:
            if self.sample_callback:
                self.sample_callback(self.device_id, sample)
            return

        ingress_port = 0
        for meta in packet.metadata:
            if meta.metadata_id == PKTIN_META_INGRESS_PORT:
                ingress_port = int.from_bytes(meta.value, byteorder='big')

        if self.packet_in_callback:
            self.packet_in_callback(self.device_id, ingress_port, packet.payload)

    def send_packet_out(self, egress_port, payload):
        # A packet-out rides the arbitration stream, which an external-control-plane client
        # never opened -- and it is a write in every sense that matters: the LLDP beacon is how
        # this proxy puts frames on somebody else's fabric. [Co-developed with claude code -- Adam]
        self._refuse_write("a packet-out")
        req = p4runtime_pb2.StreamMessageRequest()
        packet_out = req.packet
        packet_out.payload = payload
        
        # egress_port
        meta = packet_out.metadata.add()
        meta.metadata_id = 1 
        meta.value = egress_port.to_bytes(2, byteorder='big')
        
        # _pad
        meta_pad = packet_out.metadata.add()
        meta_pad.metadata_id = 2
        meta_pad.value = (0).to_bytes(1, byteorder='big')
        
        self.stream_out_q.put(req)

    def start(self, push_config=True):
        """Start the P4Runtime session and claim mastership"""
        self.is_running = True

        # [Co-developed with claude code -- Adam]
        # 🔴 An `external` fabric's controller is the primary and this client is a reader. Opening
        # a stream here would bid for mastership against it -- with an election id the package
        # chose, which either loses (useless) or WINS and takes the exercise's controller off its
        # own switch. Neither is an observation. So: no stream, no receiver thread, no
        # mastership, and every write path below raises. Reads need none of it.
        if not self.arbitration:
            print(f"[{self.device_id}] external control plane: no arbitration stream, no "
                  f"pipeline push, no writes. This client reads only.")
            return

        # 1. Open Stream and claim mastership
        req = p4runtime_pb2.StreamMessageRequest()
        req.arbitration.device_id = self.device_id
        self._bid(req.arbitration)
        self.stream_out_q.put(req)
        
        self.stream = self.stub.StreamChannel(self._stream_iterator())
        
        # Start receiver thread
        self.stream_recv_thread = threading.Thread(target=self._stream_receiver, args=(self.stream,))
        self.stream_recv_thread.daemon = True
        self.stream_recv_thread.start()
        
        # 2. Push pipeline config if provided
        if push_config:
            import time
            time.sleep(1.0)
            if self.json_path:
                self.set_forwarding_pipeline_config()

            # Only when we pushed the pipeline ourselves. The clone session lives in the
            # pipeline's PRE, so bmv2 rejects it with FAILED_PRECONDITION ("No forwarding
            # pipeline config set for this device") if no pipeline is loaded yet.
            #
            # [Co-developed with claude code -- Adam]
            # This used to sit outside the branch, which broke the one caller that matters:
            # main.py starts every switch with push_config=False so it can batch the pipeline
            # pushes, so every clone session was attempted before any pipeline existed and all
            # ten failed. When push_config is False the caller owns the ordering and must call
            # write_clone_session() itself after pushing -- main.py does, in its telemetry
            # setup.
            self.write_clone_session()

    def stop(self):
        self.is_running = False
        self.stream_out_q.put(None)
        if self.stream_recv_thread:
            self.stream_recv_thread.join(timeout=2.0)
        self.channel.close()

    @property
    def stream_alive(self) -> bool:
        """
        Whether the P4Runtime stream to this switch is still up.

        [Co-developed with claude code -- Adam]
        _stream_receiver's `for response in stream` raises grpc.RpcError when the switch goes away,
        and the thread then returns, so a dead thread means a broken stream. Corroborating evidence
        only -- it is not proof the switch is gone, because the thread also exits on a normal stop().
        """
        if not self.is_running:
            return False
        return self.stream_recv_thread is not None and self.stream_recv_thread.is_alive()

    def probe(self, timeout_s: float = 2.0) -> dict:
        """
        Round-trips one real P4Runtime RPC and reports whether the switch answered.

        [Co-developed with claude code -- Adam]
        This is the only signal that actually proves a bmv2 process is alive and serving. The
        alternatives were both weaker: grpc's channel connectivity state sits in IDLE until
        something forces a connection, so a switch killed while idle still reads as healthy, and it
        is only reachable through a private attribute; and the stream receiver thread exits on a
        clean stop() too, so it cannot tell "gone" from "shut down".

        GetForwardingPipelineConfig with COOKIE_ONLY is the cheapest request in P4Runtime -- it
        returns a single 64-bit cookie, no p4info and no device config -- and bmv2 answers it
        without touching the pipeline.

        @return {"ok": bool, "detail": str}. `detail` carries the gRPC status *name* as well as its
                details string, because bmv2 returns an empty details() for some failures and a
                report of "" is unactionable -- that already happened once with a clone session.
        """
        req = p4runtime_pb2.GetForwardingPipelineConfigRequest()
        req.device_id = self.device_id
        req.response_type = p4runtime_pb2.GetForwardingPipelineConfigRequest.COOKIE_ONLY
        try:
            self.stub.GetForwardingPipelineConfig(req, timeout=timeout_s)
            return {"ok": True, "detail": "answered GetForwardingPipelineConfig"}
        except grpc.RpcError as e:
            code = e.code().name if e.code() is not None else "UNKNOWN"
            details = e.details() or "(no details)"
            return {"ok": False, "detail": f"{code}: {details}"}
        except Exception as e:  # noqa: BLE001 -- a probe must never take the caller down
            return {"ok": False, "detail": f"{type(e).__name__}: {e}"}

    def set_forwarding_pipeline_config(self):
        # 🔴 The single most destructive call in this class: it empties every table on the switch
        # (KNOWN-ISSUES A-4c). Against a fabric whose controller is somebody else's, that would
        # delete the exercise's entire forwarding state and report success.
        # [Co-developed with claude code -- Adam]
        self._refuse_write("a pipeline push")
        print(f"[{self.device_id}] Setting Forwarding Pipeline Config...")
        req = p4runtime_pb2.SetForwardingPipelineConfigRequest()
        req.device_id = self.device_id
        self._bid(req)
        req.action = p4runtime_pb2.SetForwardingPipelineConfigRequest.VERIFY_AND_COMMIT
        with open(self.json_path, "rb") as f:
            req.config.p4_device_config = f.read()
        req.config.p4info.CopyFrom(self.p4info)
        self.stub.SetForwardingPipelineConfig(req, timeout=RPC_TIMEOUT_S)
        # [Co-developed with claude code -- Adam]
        # AFTER the RPC, never before. This line is the only record that every table entry on
        # this switch just ceased to exist (KNOWN-ISSUES A-4c); stamping it ahead of the call
        # would report a wipe for a push that was refused, and a refused push is the ordinary
        # case startup() already handles per switch. Surfaced by TopologyManager.switch_liveness
        # on GET /p4/switch_state, which the kernel already polls once a second.
        self.table_generation = boot_identity.new_table_generation()
        self.pipeline_commits += 1
        # [Co-developed with claude code -- Adam]
        # Every entry this record described has just ceased to exist, so every stamp in it is
        # now describing a rule that is not on the switch. install_initial_routes refills the
        # bring-up paths straight afterwards and re-stamps what it writes; anything it does not
        # rewrite must come back as "age unknown", not as the age of the rule the wipe removed.
        # Alongside table_generation, and after the RPC for the same reason: a refused push
        # destroyed nothing. KNOWN-ISSUES G-13, A-4c.
        self.rule_install_times.clear()
        # And the row count that record is reported against. The last read counted rows in a
        # table that no longer exists, so keeping it would pair a freshly emptied `rules_timed`
        # with the old table's `rules_total` and read as "this proxy dated none of the 40 rules
        # on this switch" -- a sentence about forty rules that are gone. Back to None, which is
        # "nobody has counted since the wipe", until the next read counts.
        self._last_table_read = None

    # [Co-developed with claude code -- Adam]
    def write_clone_session(self, session_id=SAMPLE_SESSION_ID, egress_port=CPU_PORT):
        """
        Programs the PRE clone session the pipeline samples into.

        Without this, `clone_preserving_field_list` targets a session that does not exist and
        bmv2 drops the copy without an error anywhere -- the pipeline looks correct, the proxy
        looks correct, and no telemetry ever appears. So this is a hard failure, not a warning.

        Falls back to MODIFY when INSERT fails, so a proxy restart against live switches
        reconfigures the session instead of refusing to start.

        DELETE-first, then INSERT, then a settle pair (DELETE+INSERT again) once the
        session is registered -- the settle pair is what actually heals a warm fabric,
        see below.

        Measured live (2026-08-16, reconciliation round 2): a proxy restart re-pushes the
        pipeline, and after that commit the P4Runtime server's clone-session bookkeeping is
        empty while the target's PRE state (multicast group 0x8000+session behind the
        session) survives from the previous proxy generation. The restart's INSERT then
        "succeeds" and *appends* another CPU-port replica to the surviving group -- every
        switch ended with mgid 33018 carrying two identical port-255 nodes, every sampled
        packet was cloned twice, and every twin rate and link-usage figure doubled,
        uniformly and silently (veth reconciliation caught it: twin/veth ~2.0 on all 22
        active edges). A third restart, with this DELETE in place, went 2 -> 3: the
        leading DELETE lands on the emptied bookkeeping (UNKNOWN with empty details --
        the raw-client repro's capture; this docstring first said NOT_FOUND, an inference,
        because the best-effort swallow below never logged the code) and never touches
        the orphaned group.

        The way out came from the same repro's diagnostic phase
        (doc/audit/2026-08-16_clone-stacking-raw-repro.md, phase E): a DELETE issued while
        the bookkeeping *does* hold the session destroys the whole backing multicast
        group, orphaned replicas included. After a successful registration the bookkeeping
        always holds the session -- so the settle pair below (DELETE, then INSERT again)
        collapses whatever the group accumulated across any number of pipeline re-commits
        back to exactly one replica, on every success path. Raw phases A-E: 1 node ->
        control unchanged -> 2 -> 3 -> 0 on that one delete.

        **Operational note: with the settle pair in place a proxy restart against a warm
        fabric converges back to a single replica (validated live 2026-08-16: probe-stacked
        group healed by a plain stack start). Restarting the fabric together with the
        proxy remains good hygiene -- it also clears table state -- but is no longer what
        keeps telemetry single.** The veth-vs-twin reconciliation harness is what catches
        this shape; absolute rates alone just look "busier".

        The MODIFY fallback stays, for the path where DELETE+INSERT still fails: without a
        pipeline re-push the server *does* remember the session, and that INSERT returns
        **UNKNOWN with an empty details string**, not ALREADY_EXISTS -- measured 2026-08-13
        (C9) -- so a code-specific check would silently never fire. MODIFY on the same
        session then replaces its config. Nothing is masked by being less specific: a
        genuine failure fails the MODIFY too and is reported.

        `Replica.port_kind` is a oneof: `egress_port` is the uint32 form and `port` a
        bytestring. Only one may be set. class_of_service must stay 0 -- PI rejects anything
        else as unsupported. packet_length_bytes 0 means no truncation on the switch; the
        emitter truncates instead, since it is the side with tests covering it.
        """
        self._refuse_write("a clone session write")

        def build(update_type):
            req = p4runtime_pb2.WriteRequest()
            req.device_id = self.device_id
            self._bid(req)
            update = req.updates.add()
            update.type = update_type
            session = update.entity.packet_replication_engine_entry.clone_session_entry
            session.session_id = session_id
            session.class_of_service = 0
            session.packet_length_bytes = 0
            replica = session.replicas.add()
            replica.egress_port = egress_port
            replica.instance = 1
            return req

        try:
            # Best-effort reset: a leftover session from an earlier proxy generation must go,
            # or the INSERT below appends a second replica to it (see the docstring). A
            # missing session makes this DELETE fail, which is the normal first-boot case.
            self.stub.Write(build(p4runtime_pb2.Update.DELETE), timeout=RPC_TIMEOUT_S)
        except grpc.RpcError:
            pass

        try:
            self.stub.Write(build(p4runtime_pb2.Update.INSERT), timeout=RPC_TIMEOUT_S)
            print(f"[{self.device_id}] Clone session {session_id} -> port {egress_port} installed")
        except grpc.RpcError as insert_error:
            # Any INSERT failure, not just ALREADY_EXISTS -- see the docstring. bmv2 reports a
            # duplicate session as UNKNOWN with empty details, so a code-specific check silently
            # never fired.
            try:
                self.stub.Write(build(p4runtime_pb2.Update.MODIFY), timeout=RPC_TIMEOUT_S)
                print(f"[{self.device_id}] Clone session {session_id} already present, updated "
                      f"(INSERT said {insert_error.code().name})")
            except grpc.RpcError as modify_error:
                # Both failed, so this is a real problem. The status code goes in the message,
                # not just details(): bmv2 returns some failures with an empty details() string,
                # leaving nothing to diagnose from. PERMISSION_DENIED usually means this client
                # never won mastership -- e.g. another controller is attached with the same
                # election_id.
                print(f"[{self.device_id}] Clone session {session_id} could not be programmed: "
                      f"INSERT {insert_error.code().name}: {insert_error.details()} / "
                      f"MODIFY {modify_error.code().name}: {modify_error.details()} "
                      f"-- no telemetry samples will be produced by this switch")
                return False

        # The settle pair. The session is registered now, so this DELETE is the one that
        # reaches the backing group (phase E) -- it tears down every replica the group
        # accumulated, and the INSERT rebuilds it with exactly one. Unconditional on both
        # success paths above: on a cold fabric it is a cheap rebuild of a fresh group, on
        # a warm one it is the heal. A failure here is a real failure -- reporting True
        # would hand back a session that may multiply every sample, which is the exact lie
        # the reconciliation harness had to catch once already.
        try:
            self.stub.Write(build(p4runtime_pb2.Update.DELETE), timeout=RPC_TIMEOUT_S)
            self.stub.Write(build(p4runtime_pb2.Update.INSERT), timeout=RPC_TIMEOUT_S)
            return True
        except grpc.RpcError as settle_error:
            print(f"[{self.device_id}] Clone session {session_id} settle failed "
                  f"({settle_error.code().name}: {settle_error.details()}) -- the session "
                  f"may hold stacked replicas and multiply every sample from this switch")
            return False

    # --- Helper methods for lookups ---
    def _get_table_id(self, name):
        for table in self.p4info.tables:
            if table.preamble.name == name: return table.preamble.id
        raise KeyError(f"Table {name} not found")

    def _get_action_id(self, name):
        for action in self.p4info.actions:
            if action.preamble.name == name: return action.preamble.id
        raise KeyError(f"Action {name} not found")

    def _get_match_field_id(self, table_name, match_name):
        for table in self.p4info.tables:
            if table.preamble.name == table_name:
                for match in table.match_fields:
                    if match.name == match_name: return match.id
        raise KeyError(f"Match field {match_name} not found")

    def _get_action_param_id(self, action_name, param_name):
        for action in self.p4info.actions:
            if action.preamble.name == action_name:
                for param in action.params:
                    if param.name == param_name: return param.id
        raise KeyError(f"Action parameter {param_name} not found")

    # --- Reading tables back -------------------------------------------------------
    # [Co-developed with claude code -- Adam]

    def _table_name(self, table_id):
        for table in self.p4info.tables:
            if table.preamble.id == table_id:
                return table.preamble.name
        return None

    def _action_name(self, action_id):
        for action in self.p4info.actions:
            if action.preamble.id == action_id:
                return action.preamble.name
        return None

    def _match_field_name(self, table_id, field_id):
        for table in self.p4info.tables:
            if table.preamble.id == table_id:
                for match in table.match_fields:
                    if match.id == field_id:
                        return match.name
        return None

    def _action_param_name(self, action_id, param_id):
        for action in self.p4info.actions:
            if action.preamble.id == action_id:
                for param in action.params:
                    if param.id == param_id:
                        return param.name
        return None

    def read_table_entries(self, timeout_s: float = RPC_TIMEOUT_S):
        """
        Every table entry on this switch, with p4info ids resolved to names.

        Returns a list of dicts:

            {"table": "MyIngress.ipv4_lpm",
             "priority": 0,
             "is_default": False,
             "match": {"hdr.ipv4.dstAddr": {"type": "lpm",
                                            "value": b"\\n\\x00\\x00\\x04",
                                            "prefix_len": 32}},
             "action": {"name": "MyIngress.ipv4_forward",
                        "params": {"port": b"\\x03", "dstAddr": b"..."}}}

        Ids are resolved here rather than by the caller because the caller would then need the
        p4info too, and a numeric id in the output is unreadable in a log.

        Raises nothing on a missing name -- an entry referring to an id this p4info does not
        describe is returned with None for that name, so a pipeline/p4info mismatch shows up as
        data instead of an exception on the polling path.

        [Co-developed with claude code -- Adam]
        `timeout_s` is not optional in practice. Read is a *streaming* call, and without a deadline
        it waits forever on a switch whose process is alive but not serving -- which is exactly what
        a SIGSTOPed bmv2 is. Measured 2026-08-13: with s5 stopped, GET /stats/flow/5 never returned
        (cut off at 25 s), against 3 ms healthy. A py-spy dump caught the proxy's asyncio event loop
        parked in this very frame, so the whole agent was unreachable, not just this switch --
        see the callers in api_routes for the other half of that fix.

        DEADLINE_EXCEEDED surfaces as grpc.RpcError, which get_flow_stats already turns into the
        503 + {"error": ...} body the kernel reads as ReportedFailure and keeps the previous table
        for. So a timeout degrades to "this switch was unreadable this poll", never to the empty
        table that Classifier::updateFromQueriedTables would apply as a snapshot.
        """
        req = p4runtime_pb2.ReadRequest()
        req.device_id = self.device_id
        # table_id 0 means "every table", which is what reference/dump_table.py does.
        requested = req.entities.add().table_entry
        requested.table_id = 0
        # Ask for direct-counter data. P4Runtime treats a present (even empty) counter_data in
        # the REQUEST as "send me the counters"; a bare table_id read returns entries with the
        # field unset, which is exactly what the 2026-08-24 live run measured -- every entry
        # reported 0 packets and 0 bytes, including LPM rules that had certainly carried the
        # fabric's own boot traffic. The unit tests could not see this: they hand the renderer a
        # counters dict and check it survives, which exercises everything below the switch and
        # nothing above it. [Co-developed with claude code -- Adam]
        requested.counter_data.SetInParent()

        entries = []
        for response in self.stub.Read(req, timeout=timeout_s):
            for entity in response.entities:
                if not entity.HasField("table_entry"):
                    continue
                te = entity.table_entry

                match = {}
                for m in te.match:
                    name = self._match_field_name(te.table_id, m.field_id)
                    if m.HasField("exact"):
                        match[name] = {"type": "exact", "value": m.exact.value}
                    elif m.HasField("lpm"):
                        match[name] = {"type": "lpm",
                                       "value": m.lpm.value,
                                       "prefix_len": m.lpm.prefix_len}
                    elif m.HasField("ternary"):
                        match[name] = {"type": "ternary",
                                       "value": m.ternary.value,
                                       "mask": m.ternary.mask}
                    elif m.HasField("range"):
                        match[name] = {"type": "range",
                                       "low": m.range.low,
                                       "high": m.range.high}

                action = None
                if te.action.HasField("action"):
                    a = te.action.action
                    action = {
                        "name": self._action_name(a.action_id),
                        "params": {self._action_param_name(a.action_id, p.param_id): p.value
                                   for p in a.params},
                    }

                # Direct-counter data, when the switch returns it. Both ingress tables carry a
                # direct_counter (ndtwin_switch.p4:263-264) precisely so per-entry byte and
                # packet counts can reach /stats/flow/<dpid> in the shape the kernel's
                # Classifier expects; until now they were dropped here and the renderer
                # hardcoded zeroes.
                #
                # Read defensively rather than assumed: P4Runtime only populates counter_data
                # for tables that actually have a direct counter, and a switch that does not
                # send it must degrade to 0 rather than raise on the polling path -- the same
                # rule the id lookups above follow. A zero here is therefore not proof of an
                # idle rule, only of a rule whose counter was not reported.
                # [Co-developed with claude code -- Adam]
                counters = None
                if te.HasField("counter_data"):
                    counters = {"bytes": te.counter_data.byte_count,
                                "packets": te.counter_data.packet_count}

                entries.append({
                    "table": self._table_name(te.table_id),
                    "priority": te.priority,
                    # A default action has no match fields; the kernel's Classifier would
                    # otherwise read it as a match-everything rule.
                    "is_default": te.is_default_action,
                    "match": match,
                    "action": action,
                    "counters": counters,
                })
        # [Co-developed with claude code -- Adam]
        # Noted HERE, in the one function that reads the table, rather than at the call site.
        # GET /p4/switch_state reports this as `rules_total`, the denominator that says whether
        # "0 of these rules has an age" means the proxy installed none of them or the switch
        # holds none. An additive line the flow-stats poll had to remember is a line the next
        # reader forgets, and the count would then stop moving with nothing saying so.
        #
        # After the loop, so a read that raised (a deadline against a stopped switch) leaves the
        # previous count and its age standing rather than recording a zero the switch never
        # reported -- the same rule the install record follows for a refused write.
        self._last_table_read = (len(entries), time.monotonic())
        return entries

    def last_table_read(self):
        """
        `(rows, seconds since it was read)` for the most recent `read_table_entries`, or None if
        this client has never read its tables.

        [Co-developed with claude code -- Adam]
        An age rather than a timestamp, because the caller is `switch_liveness` and everything it
        reports is an age -- the reader cannot align its monotonic clock with this process's. And
        an age rather than a bare number because the count is from the LAST read, not from one
        taken now: `GET /p4/switch_state` is `async def` and this read blocks on a gRPC stream,
        so counting on demand would put back the 2026-08-13 incident where one SIGSTOPed bmv2
        took the whole agent's event loop with it (`api_routes.get_flow_stats`' docstring). A
        count with no age would let a switch nobody has polled for an hour read as current.

        None, not `(0, ...)`: "nobody has counted this switch's rules" is not "this switch has
        no rules", and the whole of KNOWN-ISSUES G-13 is about not letting those collapse.
        """
        seen = self._last_table_read
        if seen is None:
            return None
        rows, at = seen
        return rows, max(0.0, time.monotonic() - at)

    # --- Table Operations ---
    #: The egress counter's name in ndtwin_switch.p4. A parameter rather than a literal so a test
    #: can ask for a counter that does not exist -- the negative control for the defect below.
    EGRESS_COUNTER_NAME = "MyEgress.egress_port_counter"

    def read_egress_counter(self, port, counter_name=None):
        """
        (byte_count, packet_count) for one egress port, or None if it could not be read.

        THREE OUTCOMES, THREE RETURN SHAPES.  This method used to answer `0, 0` to all of them:
        counter absent from P4Info, RPC failed, and the port genuinely forwarded nothing.  A
        caller comparing bmv2's own count against a veth counter is asking "did packets reach the
        pipeline"; the interesting answer is zero, and zero was also what a misconfigured pipeline
        and a dropped connection returned.  The instrument's failure mode was identical to its
        most newsworthy finding.  [Co-developed with claude code -- Adam]

          counter not in P4Info -> raises CounterNotFound.  Structural and permanent: the pipeline
                                   does not have this counter, so no amount of retrying helps and
                                   a number would be a fabrication.
          read failed / no entry -> returns None.  Transient: one lost sample, and the polling
                                   caller stays up, which is why the old code swallowed it. None
                                   still cannot be summed or averaged by accident.
          read succeeded         -> returns (bytes, packets), including a truthful (0, 0).

        `None` is deliberately not unpackable: `b, p = client.read_egress_counter(x)` raises at the
        call site instead of quietly binding zeros. There are no production callers today, so the
        cost of the stricter contract is zero and it is cheapest to impose before the first one.
        """
        name = counter_name if counter_name is not None else self.EGRESS_COUNTER_NAME
        counter_id = None
        for counter in self.p4info.counters:
            if counter.preamble.name == name:
                counter_id = counter.preamble.id
                break

        # `is None`, not falsiness: P4Runtime ids are unsigned and an id of 0 is falsy, so the old
        # `if not counter_id` would have reported a real counter as missing.
        if counter_id is None:
            raise CounterNotFound(
                "counter %r is not in this pipeline's P4Info (%d counters present). This is a "
                "wiring or pipeline-version error, not a measurement of zero."
                % (name, len(self.p4info.counters)))

        req = p4runtime_pb2.ReadRequest()
        req.device_id = self.device_id
        entity = req.entities.add()
        counter_entry = entity.counter_entry
        counter_entry.counter_id = counter_id
        counter_entry.index.index = port

        try:
            for response in self.stub.Read(req):
                for entity in response.entities:
                    if entity.HasField("counter_entry"):
                        data = entity.counter_entry.data
                        return data.byte_count, data.packet_count
        except Exception as e:
            logging.warning("egress counter read failed for port %s: %s -- reporting no sample, "
                            "not zero", port, e)
            return None
        # The RPC succeeded and reported nothing for this index. Still not a zero reading: bmv2
        # omits an entry it has no state for, which is a different fact from "no packets".
        logging.warning("egress counter read for port %s returned no counter_entry -- reporting "
                        "no sample, not zero", port)
        return None

    #: Byte width of each flow_5tuple key, from ndtwin_switch.p4. P4Runtime encodes a bit<N>
    #: field in ceil(N/8) bytes and bmv2 rejects a value of the wrong width outright, so these
    #: are not cosmetic. ingress_port is bit<9> -> 2 bytes, which is also why the existing
    #: ipv4_forward `port` param is written as 2 bytes rather than 1.
    #: [Co-developed with claude code -- Adam]
    _FIVE_TUPLE_KEY_BYTES = {
        "standard_metadata.ingress_port": 2,   # bit<9>
        "hdr.ipv4.srcAddr": 4,                 # bit<32>
        "hdr.ipv4.dstAddr": 4,                 # bit<32>
        "hdr.ipv4.protocol": 1,                # bit<8>
        "meta.l4_src_port": 2,                 # bit<16>
        "meta.l4_dst_port": 2,                 # bit<16>
    }

    @classmethod
    def _encode_5tuple_value(cls, p4_field, value):
        """
        (value_bytes, mask_bytes) for one ternary key.

        The mask is all-ones: every key the caller named is matched exactly. A ternary table is
        used here for its PRIORITY, not for wildcarding -- keys the caller did not name are
        simply absent from the entry, which P4Runtime already treats as "don't care". Emitting a
        partial mask would silently widen a rule the caller wrote precisely.
        [Co-developed with claude code -- Adam]
        """
        width = cls._FIVE_TUPLE_KEY_BYTES[p4_field]
        if isinstance(value, str) and "." in value:
            raw = socket.inet_aton(value)
        else:
            raw = int(value).to_bytes(width, byteorder="big")
        if len(raw) != width:
            raise ValueError(
                f"{p4_field} takes {width} byte(s), got {len(raw)} from {value!r}")
        return raw, b"\xff" * width

    # --- the install-time record. KNOWN-ISSUES G-13. [Co-developed with claude code -- Adam]
    #
    # bmv2 cannot say how old an entry is, so the write paths below say it instead: each one
    # stamps `self.rule_install_times` once the switch has ACCEPTED the write, and ryu_flow_stats
    # turns the stamp into duration_sec/duration_nsec.
    #
    # 🔴 The match handed to the record is built in the shape `read_table_entries` returns, and
    # the key is computed by rule_install_times.entry_key for both. The alternative -- each side
    # naming an entry its own way -- fails silently and completely: every lookup misses, every
    # rule reports 0/0, and the result is indistinguishable from the defect being fixed.
    #
    # The stamp is the FIRST accepted write of an entry; MODIFY does not restart it (Adam,
    # 2026-09-08, for agreement with OVS, where `duration` is the switch's own and OpenFlow
    # counts it from the ADD). So a modify records nothing new for an entry already known -- it
    # still calls record(), because a modify is also how an entry this client has never written
    # first reaches the switch.

    #: The two tables this client writes, by their p4info names -- the same strings
    #: `read_table_entries` reports through `_table_name`, because the install-time key is the
    #: table name and a second spelling would be a second key.
    IPV4_LPM_TABLE = "MyIngress.ipv4_lpm"
    FIVE_TUPLE_TABLE = "MyIngress.flow_5tuple"

    #: ipv4_lpm is an LPM table: it has no priority concept, so nothing sets `entry.priority` on
    #: those writes and bmv2 reads them back as 0. Named rather than written as a bare literal at
    #: four call sites, so the write side and the read side cannot disagree by a typo.
    LPM_ENTRY_PRIORITY = 0

    @staticmethod
    def _lpm_match(dst_ip, prefix_len):
        """An ipv4_lpm entry's match, in `read_table_entries`' shape."""
        return {"hdr.ipv4.dstAddr": {"type": "lpm",
                                     "value": socket.inet_aton(dst_ip),
                                     "prefix_len": prefix_len}}

    def _five_tuple_match(self, keys):
        """
        A flow_5tuple entry's match, in `read_table_entries`' shape.

        Encoded through `_encode_5tuple_value`, the same function `_build_5tuple_entry` puts on
        the wire, so the recorded key describes the bytes that were actually written.
        """
        out = {}
        for p4_field in sorted(keys):
            value, mask = self._encode_5tuple_value(p4_field, keys[p4_field])
            out[p4_field] = {"type": "ternary", "value": value, "mask": mask}
        return out

    def _build_5tuple_entry(self, entry, keys, priority):
        """Fills a TableEntry for MyIngress.flow_5tuple from {p4_field: value} plus a priority."""
        entry.table_id = self._get_table_id("MyIngress.flow_5tuple")
        for p4_field in sorted(keys):
            value, mask = self._encode_5tuple_value(p4_field, keys[p4_field])
            m = entry.match.add()
            m.field_id = self._get_match_field_id("MyIngress.flow_5tuple", p4_field)
            m.ternary.value = value
            m.ternary.mask = mask
        # P4Runtime requires a non-zero priority on a ternary table, and higher wins. OpenFlow
        # priority means the same thing, so it passes straight through -- this is the whole
        # reason the table exists: ipv4_lpm has no priority concept at all, so two rules the
        # kernel believed were ordered were not.
        entry.priority = int(priority)

    def insert_5tuple_rule(self, keys, priority, next_hop_mac, port):
        """
        Inserts a rule into MyIngress.flow_5tuple, which sits in front of ipv4_lpm.

        [Co-developed with claude code -- Adam]
        `keys` is {p4_field_name: value} as produced by topology_manager.five_tuple_keys.
        A match here wins over any ipv4_lpm entry for the same destination, because the pipeline
        applies flow_5tuple first and only falls through on NoAction.
        """
        self._refuse_write("a 5-tuple rule insert")
        req = p4runtime_pb2.WriteRequest()
        req.device_id = self.device_id
        self._bid(req)

        update = req.updates.add()
        update.type = p4runtime_pb2.Update.INSERT
        entry = update.entity.table_entry
        self._build_5tuple_entry(entry, keys, priority)

        action = entry.action.action
        action.action_id = self._get_action_id("MyIngress.ipv4_forward")
        p1 = action.params.add()
        p1.param_id = self._get_action_param_id("MyIngress.ipv4_forward", "dstAddr")
        p1.value = bytes.fromhex(next_hop_mac.replace(":", ""))
        p2 = action.params.add()
        p2.param_id = self._get_action_param_id("MyIngress.ipv4_forward", "port")
        p2.value = port.to_bytes(2, byteorder="big")

        try:
            self.stub.Write(req, timeout=RPC_TIMEOUT_S)
            self.rule_install_times.record(
                self.device_id, self.FIVE_TUPLE_TABLE, priority, self._five_tuple_match(keys))
            print(f"[{self.device_id}] Added 5-tuple rule prio={priority} "
                  f"{ {k.split('.')[-1]: v for k, v in keys.items()} } -> port {port}")
            return True
        except grpc.RpcError as e:
            # Same disambiguation as insert_ipv4_route: bmv2 answers UNKNOWN both for "entry
            # already exists" and for genuine failures, so rather than reading the message we do
            # what the caller meant and retry as MODIFY. If that fails too it was a real error.
            if e.code() in (grpc.StatusCode.ALREADY_EXISTS, grpc.StatusCode.UNKNOWN):
                if self.modify_5tuple_rule(keys, priority, next_hop_mac, port):
                    return True
            print(f"[{self.device_id}] Failed to add 5-tuple rule: {e.code()} - {e.details()}")
            return False

    def modify_5tuple_rule(self, keys, priority, next_hop_mac, port):
        """Modifies an existing MyIngress.flow_5tuple rule in place."""
        self._refuse_write("a 5-tuple rule modify")
        req = p4runtime_pb2.WriteRequest()
        req.device_id = self.device_id
        self._bid(req)

        update = req.updates.add()
        update.type = p4runtime_pb2.Update.MODIFY
        entry = update.entity.table_entry
        self._build_5tuple_entry(entry, keys, priority)

        action = entry.action.action
        action.action_id = self._get_action_id("MyIngress.ipv4_forward")
        p1 = action.params.add()
        p1.param_id = self._get_action_param_id("MyIngress.ipv4_forward", "dstAddr")
        p1.value = bytes.fromhex(next_hop_mac.replace(":", ""))
        p2 = action.params.add()
        p2.param_id = self._get_action_param_id("MyIngress.ipv4_forward", "port")
        p2.value = port.to_bytes(2, byteorder="big")

        try:
            self.stub.Write(req, timeout=RPC_TIMEOUT_S)
            self.rule_install_times.record(
                self.device_id, self.FIVE_TUPLE_TABLE, priority, self._five_tuple_match(keys))
            return True
        except grpc.RpcError as e:
            print(f"[{self.device_id}] Failed to modify 5-tuple rule: {e.code()} - {e.details()}")
            return False

    def delete_5tuple_rule(self, keys, priority):
        """
        Deletes a MyIngress.flow_5tuple rule.

        [Co-developed with claude code -- Adam]
        The key set AND the priority must match the installed entry: on a ternary table the
        priority is part of the entry's identity, so deleting with the wrong one removes nothing
        and reports success. That is the same shape as the OVS-side defect where
        modify_flow_entry ignored priority and edited a different rule.
        """
        self._refuse_write("a 5-tuple rule delete")
        req = p4runtime_pb2.WriteRequest()
        req.device_id = self.device_id
        self._bid(req)

        update = req.updates.add()
        update.type = p4runtime_pb2.Update.DELETE
        self._build_5tuple_entry(update.entity.table_entry, keys, priority)

        try:
            self.stub.Write(req, timeout=RPC_TIMEOUT_S)
            self.rule_install_times.forget(
                self.device_id, self.FIVE_TUPLE_TABLE, priority, self._five_tuple_match(keys))
            return True
        except grpc.RpcError as e:
            print(f"[{self.device_id}] Failed to delete 5-tuple rule: {e.code()} - {e.details()}")
            return False

    def insert_ipv4_route(self, dst_ip, prefix_len, next_hop_mac, port):
        """Inserts a rule into MyIngress.ipv4_lpm"""
        self._refuse_write("an ipv4_lpm route insert")
        req = p4runtime_pb2.WriteRequest()
        req.device_id = self.device_id
        self._bid(req)
        
        update = req.updates.add()
        update.type = p4runtime_pb2.Update.INSERT
        
        entry = update.entity.table_entry
        entry.table_id = self._get_table_id("MyIngress.ipv4_lpm")
        
        # Match: hdr.ipv4.dstAddr (LPM)
        match = entry.match.add()
        match.field_id = self._get_match_field_id("MyIngress.ipv4_lpm", "hdr.ipv4.dstAddr")
        match.lpm.value = socket.inet_aton(dst_ip)
        match.lpm.prefix_len = prefix_len
        
        # Action: MyIngress.ipv4_forward
        action = entry.action.action
        action.action_id = self._get_action_id("MyIngress.ipv4_forward")
        
        # Param: dstAddr (macAddr_t 48 bits)
        param1 = action.params.add()
        param1.param_id = self._get_action_param_id("MyIngress.ipv4_forward", "dstAddr")
        param1.value = bytes.fromhex(next_hop_mac.replace(':', ''))
        
        # Param: port (bit<9>)
        param2 = action.params.add()
        param2.param_id = self._get_action_param_id("MyIngress.ipv4_forward", "port")
        param2.value = port.to_bytes(2, byteorder='big')
        
        try:
            self.stub.Write(req, timeout=RPC_TIMEOUT_S)
            self.rule_install_times.record(
                self.device_id, self.IPV4_LPM_TABLE, self.LPM_ENTRY_PRIORITY,
                self._lpm_match(dst_ip, prefix_len))
            print(f"[{self.device_id}] Added route: {dst_ip}/{prefix_len} -> port {port}, mac {next_hop_mac}")
            return True
        except grpc.RpcError as e:
            # [Co-developed with claude code -- Adam]
            #
            # This used to `pass` on every UNKNOWN and return None either way, on the theory
            # that UNKNOWN only means "entry already exists". bmv2 does report duplicates that
            # way -- UNKNOWN with no details -- but it also returns UNKNOWN for genuine
            # failures such as a bad table name or an out-of-range action parameter, so every
            # real write error was being discarded as a harmless duplicate.
            #
            # The two cannot be told apart from the status alone, so rather than guessing from
            # the message we resolve it by doing what the caller meant: retry as a MODIFY. If
            # the entry existed, the modify succeeds and the write is genuinely done -- which
            # also fixes a second bug, since the old code left the existing entry untouched, so
            # a recalculated (better) path never actually took effect. If the modify fails too,
            # this was a real error and is reported as one.
            if e.code() in (grpc.StatusCode.ALREADY_EXISTS, grpc.StatusCode.UNKNOWN):
                if self.modify_ipv4_route(dst_ip, prefix_len, next_hop_mac, port):
                    return True

            print(f"[{self.device_id}] Failed to add route: {e.code()} - {e.details()}")
            return False

    def _ipv4_route_present(self, dst_ip, prefix_len):
        """
        Whether ipv4_lpm currently holds an entry for exactly dst_ip/prefix_len.

        [Co-developed with claude code -- Adam]
        The read-back that lets delete_ipv4_route tell "no such entry" apart from a refused
        delete, since bmv2 reports both as UNKNOWN (see there). Read-back values come
        canonicalized -- bmv2 strips leading zero bytes -- so the value is padded back to
        address width before comparing, or an address with a leading zero octet would never
        match its own entry.
        """
        want = socket.inet_aton(dst_ip)
        for entry in self.read_table_entries():
            if entry["is_default"] or entry["table"] != "MyIngress.ipv4_lpm":
                continue
            match = entry["match"].get("hdr.ipv4.dstAddr")
            if not match or match.get("type") != "lpm":
                continue
            if match["prefix_len"] == prefix_len and match["value"].rjust(4, b"\x00") == want:
                return True
        return False

    def _forget_route(self, dst_ip, prefix_len):
        """
        Drop this route's install stamp, on every path delete_ipv4_route calls success.

        All three of them, not just the clean one: bmv2 reports an already-absent entry as
        UNKNOWN with empty details rather than NOT_FOUND (live, 2026-08-16), so the read-back
        branch below is the one that actually fires, and a stamp left behind there would be
        inherited by the next rule written to the same destination.
        [Co-developed with claude code -- Adam]
        """
        self.rule_install_times.forget(self.device_id, self.IPV4_LPM_TABLE,
                                       self.LPM_ENTRY_PRIORITY,
                                       self._lpm_match(dst_ip, prefix_len))

    def delete_ipv4_route(self, dst_ip, prefix_len):
        """Deletes a rule from MyIngress.ipv4_lpm"""
        self._refuse_write("an ipv4_lpm route delete")
        req = p4runtime_pb2.WriteRequest()
        req.device_id = self.device_id
        self._bid(req)
        
        update = req.updates.add()
        update.type = p4runtime_pb2.Update.DELETE
        
        entry = update.entity.table_entry
        entry.table_id = self._get_table_id("MyIngress.ipv4_lpm")
        
        # Match: hdr.ipv4.dstAddr (LPM)
        match = entry.match.add()
        match.field_id = self._get_match_field_id("MyIngress.ipv4_lpm", "hdr.ipv4.dstAddr")
        match.lpm.value = socket.inet_aton(dst_ip)
        match.lpm.prefix_len = prefix_len
        
        try:
            self.stub.Write(req, timeout=RPC_TIMEOUT_S)
            self._forget_route(dst_ip, prefix_len)
            print(f"[{self.device_id}] Deleted route: {dst_ip}/{prefix_len}")
            return True
        except grpc.RpcError as e:
            # [Co-developed with claude code -- Adam]
            # NOT_FOUND means the entry is already gone, which is what the caller wanted, so
            # it counts as success. Anything else is a real failure and must be reported --
            # previously every outcome returned None and route_flow answered "success".
            if e.code() == grpc.StatusCode.NOT_FOUND:
                self._forget_route(dst_ip, prefix_len)
                return True
            # [Co-developed with claude code -- Adam]
            # bmv2 never actually says NOT_FOUND: deleting an entry that is not there comes
            # back UNKNOWN with empty details (live, 2026-08-16), the same opaque status it
            # uses for genuine failures -- so against the real switch the branch above is
            # dead and the idempotent-teardown intent degraded to an error the kernel logs
            # as a failed flow removal. Worse, unroute_flow skips its bookkeeping on False,
            # so a rule already gone from the switch could never be cleared from
            # _installed_routes and the twin kept advertising it. Same ambiguity as
            # insert_ipv4_route's duplicate case, resolved the same way: by checking whether
            # the caller's goal state holds. Gone -- no matter who removed it -- is done;
            # still present, or unreadable, stays an honest failure.
            if e.code() == grpc.StatusCode.UNKNOWN:
                try:
                    if not self._ipv4_route_present(dst_ip, prefix_len):
                        self._forget_route(dst_ip, prefix_len)
                        return True
                except grpc.RpcError:
                    pass
            print(f"[{self.device_id}] Failed to delete route: {e.code()} - {e.details()}")
            return False

    def modify_ipv4_route(self, dst_ip, prefix_len, next_hop_mac, port):
        """Modifies a rule in MyIngress.ipv4_lpm"""
        self._refuse_write("an ipv4_lpm route modify")
        req = p4runtime_pb2.WriteRequest()
        req.device_id = self.device_id
        self._bid(req)
        
        update = req.updates.add()
        update.type = p4runtime_pb2.Update.MODIFY
        
        entry = update.entity.table_entry
        entry.table_id = self._get_table_id("MyIngress.ipv4_lpm")
        
        # Match: hdr.ipv4.dstAddr (LPM)
        match = entry.match.add()
        match.field_id = self._get_match_field_id("MyIngress.ipv4_lpm", "hdr.ipv4.dstAddr")
        match.lpm.value = socket.inet_aton(dst_ip)
        match.lpm.prefix_len = prefix_len
        
        # Action: MyIngress.ipv4_forward
        action = entry.action.action
        action.action_id = self._get_action_id("MyIngress.ipv4_forward")
        
        # Param: dstAddr (macAddr_t 48 bits)
        param1 = action.params.add()
        param1.param_id = self._get_action_param_id("MyIngress.ipv4_forward", "dstAddr")
        param1.value = bytes.fromhex(next_hop_mac.replace(':', ''))
        
        # Param: port (bit<9>)
        param2 = action.params.add()
        param2.param_id = self._get_action_param_id("MyIngress.ipv4_forward", "port")
        param2.value = port.to_bytes(2, byteorder='big')
        
        # [Co-developed with claude code -- Adam]
        # The success path had no `return True`, so it fell off the end returning None.
        # topology_manager.modify_flow passed that straight through and api_routes raised
        # HTTPException(400) -- every *successful* modify answered HTTP 400.
        try:
            self.stub.Write(req, timeout=RPC_TIMEOUT_S)
            self.rule_install_times.record(
                self.device_id, self.IPV4_LPM_TABLE, self.LPM_ENTRY_PRIORITY,
                self._lpm_match(dst_ip, prefix_len))
            print(f"[{self.device_id}] Modified route: {dst_ip}/{prefix_len} -> port {port}, mac {next_hop_mac}")
            return True
        except grpc.RpcError as e:
            print(f"[{self.device_id}] Failed to modify route: {e.code()} - {e.details()}")
            return False

# Developed in collaboration with Gemini 3.1 Pro.
