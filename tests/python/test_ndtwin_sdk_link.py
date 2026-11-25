#!/usr/bin/env python3
"""`k.link_down` and `k.restore_link` of sdk/python/ndtwin against an in-process fake of the
kernel's link-injection routes (tests/python/link_fake_kernel.py).

[Co-developed with claude code -- Adam]

The SDK is imported from sdk/python (or $NDTWIN_SDK_UNDER_TEST, which
tests/shell/mutate_ndtwin_sdk_link.sh points at its mutated copies). Covered: the two POSTs and
their bodies, the recovery when the block ends in every way it can, what `cut` says about the wire,
how each reply of both routes maps onto an exception, what is refused before anything is sent,
and that neither POST is sent twice. Every canned reply names, in link_fake_kernel.py or beside it
here, the kernel line (at 922d9e4ec) it was copied from, or says it is made up and why. Standard
library only; runs under Python 3.8 too.

    python3 tests/python/test_ndtwin_sdk_link.py -v
"""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import link_fake_kernel as fk  # noqa: E402

SDK_DIR = os.environ.get("NDTWIN_SDK_UNDER_TEST") or os.path.join(REPO, "sdk", "python")
sys.path.insert(0, SDK_DIR)
import ndtwin  # noqa: E402

INJECT, RECOVER, GRAPH = fk.INJECT, fk.RECOVER, fk.GRAPH
ENDS = ((1, 1), (2, 1))
BODY = {"src_dpid": 1, "src_interface": 1, "dst_dpid": 2, "dst_interface": 1}
IFACES = ("s1-eth1", "s2-eth1")
# A cut whose second attach tc refused and whose rollback of the first could not be deleted: the
# netem stays on s1-eth1 alone (cutLinkEnds phase 2 and 3, NLF:845-889).
HALF_CUT = fk.not_attached(
    [fk.rolled_back("s1-eth1", "s2-eth1: tc refused the attach (status 2)",
                    fk.delete_refused("s1-eth1")),
     fk.attach_refused("s2-eth1")], "s2-eth1: tc refused the attach (status 2)")


class Boom(Exception):
    pass


class LinkTest(unittest.TestCase):
    def setUp(self):
        self.fake = fk.LinkFakeKernel()
        self.server = fk.serve(self.fake)
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.k = ndtwin.Kernel(self.url, timeout=5, retry_wait=0)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def link(self, src=1, src_port=1):
        """The Link of the topology the kernel serves, as an app has it."""
        return next(l for l in self.k.topology().links if (l.src, l.src_port) == (src, src_port))

    def posts(self, path=None):
        return self.fake.posts(path)

    def stop_kernel(self):
        """Close the fake's port: every request after this finds nobody listening."""
        self.server.shutdown()
        self.server.server_close()


class CutAndRestoreTest(LinkTest):
    """The normal cut and restore."""

    def test_the_block_is_one_injection_and_one_recovery_with_exact_bodies(self):
        link = self.link()
        self.fake.requests.clear()
        with self.k.link_down(link) as cut:
            self.assertEqual(self.posts(), [BODY])
            self.assertEqual(self.fake.netem, {"s1-eth1": "ours", "s2-eth1": "ours"})
        self.assertEqual([(m, p, b) for m, p, b in self.fake.requests if m == "POST"],
                         [("POST", INJECT, BODY), ("POST", RECOVER, BODY)])
        self.assertEqual((self.fake.netem, self.fake.declared), ({}, set()))
        self.assertIsInstance(cut, ndtwin.LinkCut)
        self.assertIsInstance(cut.restored, ndtwin.LinkRestore)
        self.assertEqual(cut.restored.removed, IFACES)
        self.assertEqual(cut.restored.still_cut, ())
        self.assertIsNone(cut.restore_error)

    def test_the_cut_says_it_is_on_the_wire_and_where(self):
        with self.k.link_down(self.link()) as cut:
            self.assertIs(cut.on_wire, True)
            self.assertEqual(cut.interfaces, IFACES)
            self.assertIsNone(cut.why)
            self.assertEqual(cut.status, "link failure injected")
            self.assertEqual(cut.lab_claim, fk.LAB_CLAIM)
            self.assertEqual([e["interface"] for e in cut.tc], list(IFACES))

    def test_two_ends_and_the_other_direction_name_the_link_as_given(self):
        with self.k.link_down(((2, 1), (1, 1))):
            pass
        rev = {"src_dpid": 2, "src_interface": 1, "dst_dpid": 1, "dst_interface": 1}
        self.assertEqual(self.posts(), [rev, rev])
        with self.k.link_down(self.link(2, 1)):
            pass
        self.assertEqual(self.posts()[2:], [rev, rev])

    def test_the_body_names_each_end_with_its_own_port(self):
        with self.k.link_down(((3, 1), (2, 2))) as cut:
            self.assertEqual(cut.interfaces, ("s3-eth1", "s2-eth2"))
        body = {"src_dpid": 3, "src_interface": 1, "dst_dpid": 2, "dst_interface": 2}
        self.assertEqual(self.posts(), [body, body])

    def test_the_topology_shows_the_link_declared_inside_the_block(self):
        with self.k.link_down(self.link()):
            reasons = {(l.src, l.dst): l.down_reason for l in self.k.topology().links}
            self.assertEqual((reasons[(1, 2)], reasons[(2, 1)]), ("declared", "declared"))
            self.assertEqual(reasons[(2, 3)], "none")
        self.assertEqual(self.link().down_reason, "none")


class BlockEndsTest(LinkTest):
    """The recovery when the block raises, is interrupted, or the recovery itself fails."""

    def test_the_restore_is_sent_when_the_block_raises_and_its_exception_goes_on(self):
        with self.assertRaises(Boom) as caught:
            with self.k.link_down(self.link()) as cut:
                raise Boom("the app failed")
        self.assertEqual(str(caught.exception), "the app failed")
        self.assertEqual(len(self.posts(RECOVER)), 1)
        self.assertEqual(self.fake.netem, {})
        self.assertEqual(cut.restored.removed, IFACES)
        self.assertFalse(hasattr(caught.exception, "link_not_restored"))

    def test_ctrl_c_in_the_block_still_restores(self):
        with self.assertRaises(KeyboardInterrupt):
            with self.k.link_down(self.link()):
                raise KeyboardInterrupt
        self.assertEqual(len(self.posts(RECOVER)), 1)
        self.assertEqual((self.fake.netem, self.fake.declared), ({}, set()))

    def test_a_failed_restore_after_a_clean_block_says_the_link_may_still_be_cut(self):
        # HS.cpp:609-616: the router's 500 for an exception anywhere in the handler.
        self.fake.script("POST", RECOVER, (500, fk.INTERNAL))
        with self.assertRaises(ndtwin.LinkNotRestored) as caught:
            with self.k.link_down(self.link()) as cut:
                pass
        err = caught.exception
        self.assertIn("may still be cut", str(err))
        self.assertIn("k.restore_link(((1, 1), (2, 1)))", str(err))
        self.assertEqual(err.remedy, "k.restore_link(((1, 1), (2, 1)))")
        self.assertEqual(err.still_cut, IFACES)
        self.assertIsNone(err.nothing_written)
        self.assertIs(cut.restore_error, err)
        self.assertEqual(len(self.posts(RECOVER)), 1)

    def test_a_failed_restore_while_the_block_raised_keeps_the_blocks_exception(self):
        self.fake.script("POST", RECOVER, (500, fk.INTERNAL))
        with self.assertRaises(Boom) as caught:
            with self.k.link_down(self.link()) as cut:
                raise Boom("the app failed")
        self.assertTrue(hasattr(caught.exception, "link_not_restored"),
                        "the failed restore is not on the block's exception")
        attached = caught.exception.link_not_restored
        self.assertIsInstance(attached, ndtwin.LinkNotRestored)
        self.assertIs(cut.restore_error, attached)
        self.assertIn("may still be cut", str(attached))
        if hasattr(caught.exception, "add_note"):
            self.assertEqual(caught.exception.__notes__, [str(attached)])
        self.assertEqual(len(self.posts(RECOVER)), 1)

    def test_a_kernel_that_restarted_during_the_block_leaves_the_link_maybe_cut(self):
        # The restarted kernel holds no declaration and does not own the netem (doc §2c), so the
        # recovery is refused with 409 and changes nothing; the link is still cut.
        with self.assertRaises(ndtwin.LinkNotRestored) as caught:
            with self.k.link_down(self.link()):
                self.fake.declared.clear()
                self.fake.netem = {"s1-eth1": "foreign", "s2-eth1": "foreign"}
        err = caught.exception
        self.assertIsNone(err.nothing_written)
        self.assertEqual(err.status, 409)
        self.assertIs(err.__cause__.nothing_written, True)
        self.assertEqual(err.still_cut, IFACES)
        self.assertNotIn("k.restore_link", err.remedy)
        self.assertIn("by hand", err.remedy)

    def test_a_kernel_unreachable_at_the_end_of_the_block_leaves_the_link_maybe_cut(self):
        with self.assertRaises(ndtwin.LinkNotRestored) as caught:
            with self.k.link_down(self.link()):
                self.stop_kernel()
        err = caught.exception
        self.assertIsInstance(err.__cause__, ndtwin.KernelUnreachable)
        self.assertIsNone(err.nothing_written)
        self.assertEqual(err.still_cut, IFACES)
        self.assertEqual(err.remedy, "k.restore_link(((1, 1), (2, 1)))")

    def test_a_failed_restore_after_ctrl_c_keeps_the_interrupt(self):
        self.fake.script("POST", RECOVER, None)
        with self.assertRaises(KeyboardInterrupt) as caught:
            with self.k.link_down(self.link()):
                raise KeyboardInterrupt
        self.assertIsInstance(caught.exception.link_not_restored, ndtwin.LinkNotRestored)


class OnTheWireTest(LinkTest):
    """What `cut` says when the netem is not on every end."""

    def test_tc_skipped_is_not_on_the_wire_and_the_block_runs(self):
        self.fake.mininet = False
        ran = []
        with self.k.link_down(self.link()) as cut:
            ran.append(cut.on_wire)
            self.assertEqual(cut.interfaces, ())
            self.assertIn("this injection attached no netem", cut.why)
            self.assertEqual(cut.tc, fk.SKIPPED)
        self.assertEqual(ran, [False])
        self.assertEqual(len(self.posts(RECOVER)), 1)
        self.assertEqual(cut.restored.tc, fk.SKIPPED)

    def test_a_refused_cut_is_not_on_the_wire_and_a_netem_it_did_not_attach_is_reported(self):
        self.fake.netem["s2-eth1"] = "foreign"      # somebody else's experiment
        with self.k.link_down(self.link()) as cut:
            self.assertIs(cut.on_wire, False)
            self.assertEqual(cut.interfaces, ())
            self.assertIn("netem is already attached", cut.why)
        self.assertEqual(cut.restored.still_cut, ("s2-eth1",))
        self.assertEqual(self.fake.netem, {"s2-eth1": "foreign"})
        self.assertEqual(self.fake.declared, set())

    def test_a_rollback_that_worked_is_not_on_the_wire(self):
        blocked = "s2-eth1: tc refused the attach (status 2)"
        reply = fk.not_attached([fk.rolled_back("s1-eth1", blocked, fk.removed("s1-eth1")),
                                 fk.attach_refused("s2-eth1")], blocked)
        self.fake.script("POST", INJECT, (200, reply))   # NLF:845-889, phase 2 then phase 3
        with self.k.link_down(self.link()) as cut:
            self.assertIs(cut.on_wire, False)
        self.assertEqual(len(self.posts(RECOVER)), 1)

    def test_a_netem_left_on_one_end_does_not_enter_and_is_taken_off(self):
        self.fake.script("POST", INJECT, (200, HALF_CUT))  # NLF:872-886 with a failed rollback
        self.fake.netem["s1-eth1"] = "ours"                 # what that reply leaves on the wire
        ran = []
        with self.assertRaises(ndtwin.NDTwinError) as caught:
            with self.k.link_down(self.link()):
                ran.append(1)
        err = caught.exception
        self.assertEqual(ran, [])
        self.assertNotIsInstance(err, ndtwin.LinkNotRestored)
        self.assertIn("s1-eth1", str(err))
        self.assertEqual(len(self.posts(RECOVER)), 1)
        self.assertEqual(self.fake.netem, {})

    def test_the_half_cut_error_carries_the_recovery_and_may_have_landed(self):
        self.fake.script("POST", INJECT, (200, HALF_CUT))
        self.fake.netem["s1-eth1"] = "ours"
        with self.assertRaises(ndtwin.NDTwinError) as caught:
            with self.k.link_down(self.link()):
                pass
        err = caught.exception
        self.assertIsNone(err.nothing_written)
        self.assertTrue(hasattr(err, "restore"), "the recovery's LinkRestore is not on the error")
        self.assertIsInstance(err.restore, ndtwin.LinkRestore)
        self.assertEqual(err.restore.removed, ("s1-eth1",))
        self.assertNotIn("no netem was attached", str(err))

    def test_a_netem_left_on_one_end_that_stays_raises_link_not_restored(self):
        self.fake.script("POST", INJECT, (200, HALF_CUT))
        self.fake.script("POST", RECOVER, (200, fk.recovered([
            fk.delete_refused("s1-eth1"), fk.noop("s2-eth1")])))
        with self.assertRaises(ndtwin.LinkNotRestored) as caught:
            with self.k.link_down(self.link()):
                pass
        self.assertEqual(caught.exception.still_cut, ("s1-eth1",))
        self.assertIsNone(caught.exception.nothing_written)

    def test_an_end_the_kernel_cannot_name_is_not_on_the_wire_and_the_block_runs(self):
        self.fake.no_bridge.add(2)
        ran = []
        with self.k.link_down(self.link()) as cut:
            ran.append(cut.on_wire)
            self.assertEqual(cut.interfaces, ())
            self.assertIn("no bridge_name", cut.why)
        self.assertEqual(ran, [False])
        self.assertEqual(cut.restored.still_cut, (None,))
        self.assertEqual(self.fake.netem, {})


# Made up: the kernel names both ends of a cut it attached (NLF:758-767 refuses before attaching
# when it cannot) and its 409 always lists netem_not_ours (HS.cpp:1453). A cut whose unnamed end
# kept its netem, and a 409 without that list, hold the SDK to reporting them without a TypeError.
UNNAMED_CUT = fk.injected([dict(fk.rolled_back("s1-eth1", "made up", fk.delete_refused("s1-eth1")),
                                interface=None), fk.cut_ok("s2-eth1")])
BARE_409 = {"error": "not declared by this kernel"}


class UnnamedEndTest(LinkTest):
    """An end without an interface name, in every message that names interfaces."""

    def test_an_unnamed_end_refused_at_exit_is_reported_as_such(self):
        self.fake.script("POST", INJECT, (200, UNNAMED_CUT))
        self.fake.script("POST", RECOVER, (409, BARE_409))
        with self.assertRaises(ndtwin.LinkNotRestored) as caught:
            with self.k.link_down(self.link()) as cut:
                self.assertEqual(cut.interfaces, (None, "s2-eth1"))
        err = caught.exception
        self.assertEqual(err.still_cut, (None, "s2-eth1"))
        self.assertIn("s2-eth1, an end the kernel did not name", err.remedy)
        self.assertNotIn("None", err.remedy)

    def test_an_unnamed_end_refused_after_ctrl_c_keeps_the_interrupt(self):
        self.fake.script("POST", INJECT, (200, UNNAMED_CUT))
        self.fake.script("POST", RECOVER, (409, BARE_409))
        with self.assertRaises(KeyboardInterrupt) as caught:
            with self.k.link_down(self.link()):
                raise KeyboardInterrupt
        self.assertTrue(hasattr(caught.exception, "link_not_restored"),
                        "the failed restore is not on the interrupt")
        self.assertIn("an end the kernel did not name",
                      str(caught.exception.link_not_restored))


class ExitNotCleanTest(LinkTest):
    """A recovery that answers 200 and does not clear what the injection attached."""

    def test_an_unreadable_tree_on_an_attached_interface_is_not_a_clean_exit(self):
        self.fake.script("POST", RECOVER, (200, fk.recovered(
            [fk.removed("s1-eth1"), fk.unreadable("s2-eth1")])))
        with self.assertRaises(ndtwin.LinkNotRestored) as caught:
            with self.k.link_down(self.link()):
                pass
        err = caught.exception
        self.assertEqual(err.still_cut, ("s2-eth1",))
        self.assertEqual([e["interface"] for e in err.tc], list(IFACES))
        self.assertIn("could not read the qdisc tree", str(err))
        self.assertEqual(err.restore.removed, ("s1-eth1",))

    def test_a_netem_left_standing_on_an_attached_interface_is_not_a_clean_exit(self):
        with self.assertRaises(ndtwin.LinkNotRestored) as caught:
            with self.k.link_down(self.link()):
                self.fake.netem["s1-eth1"] = "replaced"     # somebody replaced this kernel's
        err = caught.exception
        self.assertEqual(err.still_cut, ("s1-eth1",))
        self.assertIn("sudo tc qdisc del dev s1-eth1", err.remedy)
        self.assertNotIn("k.restore_link", err.remedy)
        self.assertIn("somebody replaced it", str(err))

    def test_tc_skipped_on_the_recovery_of_a_cut_is_not_a_clean_exit(self):
        # Made up: the kernel was restarted in another deployment mode during the block.
        self.fake.script("POST", RECOVER, (200, {"status": "link recovery injected",
                                                 "tc": fk.SKIPPED}))
        with self.assertRaises(ndtwin.LinkNotRestored) as caught:
            with self.k.link_down(self.link()):
                pass
        self.assertEqual(caught.exception.still_cut, IFACES)


class RefusalsTest(LinkTest):
    """Each refusal of both routes."""

    REFUSALS = ((400, fk.INVALID, ndtwin.Refused), (400, fk.HOST_EDGE, ndtwin.Refused),
                (404, fk.NO_EDGE, ndtwin.NotFound), (404, fk.WRONG_PORTS, ndtwin.NotFound))

    def test_each_refusal_of_the_injection_changes_nothing_and_runs_no_block(self):
        for status, body, cls in self.REFUSALS:
            with self.subTest(body=body):
                self.fake.requests.clear()
                self.fake.script("POST", INJECT, (status, body))
                with self.assertRaises(cls) as caught:
                    with self.k.link_down(self.link()):
                        self.fail("the block ran")
                self.assertIs(caught.exception.nothing_written, True)
                self.assertEqual(caught.exception.lab_claim, fk.LAB_CLAIM)
                self.assertEqual((len(self.posts(INJECT)), len(self.posts(RECOVER))), (1, 0))

    def test_a_kernel_unreachable_at_the_injection_changes_nothing(self):
        topology = self.k.topology

        def read_then_stop():
            topo = topology()
            self.stop_kernel()
            return topo

        self.k.topology = read_then_stop
        with self.assertRaises(ndtwin.KernelUnreachable) as caught:
            with self.k.link_down(ENDS):
                self.fail("the block ran")
        self.assertIs(caught.exception.nothing_written, True)
        self.assertEqual(self.posts(), [])

    def test_the_injections_500_that_says_nothing_was_injected_is_not_unknown(self):
        self.fake.script("POST", INJECT, (500, fk.NO_REVERSE_INJECT))
        with self.assertRaises(ndtwin.NDTwinError) as caught:
            with self.k.link_down(self.link()):
                self.fail("the block ran")
        self.assertNotIsInstance(caught.exception, ndtwin.OutcomeUnknown)
        self.assertIs(caught.exception.nothing_written, True)
        self.assertEqual(len(self.posts()), 1)

    def test_each_refusal_of_the_recovery_at_the_end_of_the_block_is_link_not_restored(self):
        for status, body in ((400, fk.INVALID), (400, fk.HOST_EDGE), (404, fk.NO_EDGE),
                             (404, fk.WRONG_PORTS), (500, fk.NO_REVERSE_RECOVER),
                             (409, fk.conflict(["s2-eth1"]))):
            with self.subTest(status=status, body=body):
                self.fake.requests.clear()
                self.fake.script("POST", RECOVER, (status, body))
                with self.assertRaises(ndtwin.LinkNotRestored) as caught:
                    with self.k.link_down(self.link()):
                        pass
                err = caught.exception
                self.assertIsNone(err.nothing_written)      # the link may still be cut
                self.assertIs(err.__cause__.nothing_written, True)
                self.assertEqual(err.status, status)
                self.assertIn("may still be cut", str(err))
                self.assertEqual(len(self.posts(RECOVER)), 1)
                self.fake.netem.clear()
                self.fake.declared.clear()

    def test_the_409_names_the_netem_that_is_not_this_kernels(self):
        self.fake.script("POST", RECOVER, (409, fk.conflict(["s2-eth1"])))
        with self.assertRaises(ndtwin.LinkNotRestored) as caught:
            self.k.restore_link(ENDS)
        self.assertEqual(caught.exception.still_cut, ("s2-eth1",))
        self.assertEqual(caught.exception.lab_claim, fk.LAB_CLAIM)
        self.assertIs(caught.exception.nothing_written, True)
        self.assertNotIn("k.restore_link", caught.exception.remedy)
        self.assertIn("by hand", caught.exception.remedy)


class UnknownOutcomeTest(LinkTest):
    """Outcomes the SDK cannot know, on entry and on exit; each POST is sent once."""

    # The 502 is made up: the kernel's router does not answer it on these routes; a proxy in
    # front of the kernel could.
    UNKNOWN = ((500, fk.INTERNAL), (400, fk.JSON_ERROR), (502, fk.INTERNAL), None)

    def test_an_unknown_injection_is_outcome_unknown_naming_the_restore(self):
        for reply in self.UNKNOWN:
            with self.subTest(reply=reply):
                self.fake.requests.clear()
                self.fake.script("POST", INJECT, reply)
                with self.assertRaises(ndtwin.OutcomeUnknown) as caught:
                    with self.k.link_down(self.link()):
                        self.fail("the block ran")
                err = caught.exception
                self.assertIsNone(err.nothing_written)
                self.assertEqual(err.remedy, "k.restore_link(((1, 1), (2, 1)))")
                self.assertIn("may be cut", str(err))
                self.assertEqual((len(self.posts(INJECT)), len(self.posts(RECOVER))), (1, 0))

    def test_an_unknown_recovery_is_link_not_restored_and_sent_once(self):
        for reply in self.UNKNOWN:
            with self.subTest(reply=reply):
                self.fake.requests.clear()
                self.fake.script("POST", RECOVER, reply)
                with self.assertRaises(ndtwin.LinkNotRestored) as caught:
                    with self.k.link_down(self.link()):
                        pass
                self.assertIsNone(caught.exception.nothing_written)
                self.assertIsInstance(caught.exception.__cause__, ndtwin.OutcomeUnknown)
                self.assertEqual(len(self.posts(RECOVER)), 1)
                self.fake.netem.clear()
                self.fake.declared.clear()


# Made up: 200 bodies the kernel does not send, to hold the SDK to raising its own exceptions.
UNREADABLE = (b"not json", [], {}, {"status": "link failure injected"},
              {"status": "link failure injected", "tc": "x"},
              {"status": "link failure injected", "tc": []},
              {"status": "link failure injected", "tc": [{"interface": "s1-eth1"}]},
              {"status": "link failure injected", "tc": [{"interface": "s1-eth1", "ok": "true"}]},
              {"status": "link failure injected", "tc": [{"interface": 7, "ok": True}]},
              {"status": "link failure injected", "tc": [{"interface": None, "ok": True}]},
              {"status": 3, "tc": fk.SKIPPED}, {"tc": fk.SKIPPED}, None)


class UnreadableReplyTest(LinkTest):
    def test_an_injection_reply_the_sdk_cannot_read_is_outcome_unknown(self):
        for body in UNREADABLE:
            with self.subTest(body=body):
                self.fake.requests.clear()
                self.fake.script("POST", INJECT, (200, b"" if body is None else body))
                with self.assertRaises(ndtwin.NDTwinError) as caught:
                    with self.k.link_down(self.link()):
                        self.fail("the block ran")
                self.assertIsInstance(caught.exception, ndtwin.OutcomeUnknown)
                self.assertEqual(caught.exception.remedy, "k.restore_link(((1, 1), (2, 1)))")
                self.assertEqual(len(self.posts()), 1)

    def test_a_recovery_reply_the_sdk_cannot_read_is_link_not_restored(self):
        for body in UNREADABLE:
            with self.subTest(body=body):
                self.fake.requests.clear()
                self.fake.script("POST", RECOVER, (200, b"" if body is None else body))
                with self.assertRaises(ndtwin.NDTwinError) as caught:
                    with self.k.link_down(self.link()):
                        pass
                self.assertIsInstance(caught.exception, ndtwin.LinkNotRestored)
                self.assertIsNone(caught.exception.nothing_written)
                self.assertEqual(len(self.posts(RECOVER)), 1)
                self.fake.netem.clear()
                self.fake.declared.clear()

    def test_a_restore_link_reply_the_sdk_cannot_read_is_link_not_restored(self):
        for body in UNREADABLE:
            with self.subTest(body=body):
                self.fake.script("POST", RECOVER, (200, b"" if body is None else body))
                with self.assertRaises(ndtwin.NDTwinError) as caught:
                    self.k.restore_link(ENDS)
                self.assertIsInstance(caught.exception, ndtwin.LinkNotRestored)


class BeforeSendingTest(LinkTest):
    """What is refused before anything is sent."""

    def test_a_host_facing_link_of_the_topology_is_refused_before_sending(self):
        host = next(l for l in self.k.topology().links if l.dst == 0)
        self.fake.requests.clear()
        for call in (lambda: self.k.link_down(host).__enter__(),
                     lambda: self.k.restore_link(host)):
            with self.assertRaises(ndtwin.Refused) as caught:
                call()
            self.assertIs(caught.exception.nothing_written, True)
            self.assertIn("host-facing", str(caught.exception))
        self.assertEqual(self.fake.requests, [])

    def test_a_link_not_in_the_topology_as_given_is_not_found_before_sending(self):
        for ends in (((1, 3), (2, 1)), ((1, 1), (3, 1)), ((1, 1), (2, 2))):
            with self.subTest(ends=ends):
                with self.assertRaises(ndtwin.NotFound):
                    self.k.link_down(ends).__enter__()
        self.assertEqual(self.posts(), [])

    def test_a_link_that_shares_its_switches_with_another_is_refused_before_sending(self):
        self.fake.cables.append((1, 2, 2, 3))
        with self.assertRaises(ndtwin.Refused) as caught:
            self.k.link_down(ENDS).__enter__()
        self.assertIn("s1:2-s2:3", str(caught.exception))
        self.assertEqual(self.posts(), [])

    def test_a_link_already_declared_down_is_refused_before_sending(self):
        self.fake.declared.add(frozenset((1, 2)))
        with self.assertRaises(ndtwin.Refused) as caught:
            self.k.link_down(ENDS).__enter__()
        self.assertIn("already declared down", str(caught.exception))
        self.assertEqual(self.posts(), [])

    def test_a_nested_block_on_the_same_link_is_refused_and_leaves_the_outer_cut(self):
        with self.k.link_down(ENDS):
            with self.assertRaises(ndtwin.Refused):
                with self.k.link_down(((2, 1), (1, 1))):
                    pass
            self.assertEqual(self.fake.netem, {"s1-eth1": "ours", "s2-eth1": "ours"})
        self.assertEqual(len(self.posts()), 2)

    def test_restore_link_refuses_a_link_the_kernel_would_address_wrongly(self):
        self.fake.handle("POST", INJECT, BODY)       # s1:1-s2:1 is cut
        self.fake.cables.append((1, 2, 3, 2))
        self.fake.requests.clear()
        # The SDK refuses these before sending. The kernel answers a wrong port with 404 as well
        # (link_fake_kernel.link_route); kernels before that check found the link by its two
        # switches and removed netem on the ports given, so a wrong port withdrew the declaration
        # and left this kernel's netem on s1-eth1 and s2-eth1.
        for ends, cls in ((((1, 1), (2, 2)), ndtwin.NotFound), (((1, 3), (2, 1)), ndtwin.NotFound)):
            with self.subTest(ends=ends):
                with self.assertRaises(cls):
                    self.k.restore_link(ends)
        self.fake.cables.append((1, 4, 2, 4))
        with self.assertRaises(ndtwin.Refused) as caught:
            self.k.restore_link(ENDS)
        self.assertIn("s1:4-s2:4", str(caught.exception))
        self.assertEqual(self.posts(), [])
        self.assertEqual(self.fake.netem, {"s1-eth1": "ours", "s2-eth1": "ours"})
        self.assertEqual(self.fake.declared, {frozenset((1, 2))})

    def test_a_graph_the_sdk_cannot_read_is_an_sdk_error(self):
        # Made up: graphs the kernel does not serve, to hold the SDK to its own exceptions.
        bad_port = self.fake.graph()
        bad_port["edges"][0].update(is_up=False, src_interface=[1])
        not_a_list = dict(self.fake.graph(), edges={"a": 1})
        for graph in (bad_port, not_a_list):
            for call in (lambda: self.k.link_down(ENDS).__enter__(),
                         lambda: self.k.restore_link(ENDS)):
                with self.subTest(graph=str(graph["edges"])[:40]):
                    self.fake.script("GET", GRAPH, (200, graph))
                    with self.assertRaises(ndtwin.NDTwinError):
                        call()
        self.assertEqual(self.posts(), [])

    def test_what_is_not_a_link_is_a_value_error(self):
        for bad in (None, 5, (1, 2), ((1, 1),), ((1, "1"), (2, 1)), ((True, 1), (2, 1)),
                    ((-1, 1), (2, 1)), ((1, 1), (2, 1.0))):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    self.k.link_down(bad).__enter__()
                with self.assertRaises(ValueError):
                    self.k.restore_link(bad)
        self.assertEqual(self.fake.requests, [])


class RestoreLinkTest(LinkTest):
    """`k.restore_link` on its own, for a cut that no block ended."""

    def killed_app(self):
        """What a killed app leaves: the injection's netem and declaration."""
        self.fake.handle("POST", INJECT, BODY)
        self.fake.requests.clear()

    def test_it_takes_off_what_this_kernel_attached(self):
        self.killed_app()
        done = self.k.restore_link(self.link())
        self.assertIsInstance(done, ndtwin.LinkRestore)
        self.assertEqual(self.posts(), [BODY])
        self.assertEqual((done.removed, done.still_cut), (IFACES, ()))
        self.assertEqual(done.status, "link recovery injected")
        self.assertEqual(done.lab_claim, fk.LAB_CLAIM)
        self.assertEqual((self.fake.netem, self.fake.declared), ({}, set()))

    def test_a_link_with_nothing_to_restore_is_a_noop(self):
        done = self.k.restore_link(ENDS)
        self.assertEqual((done.removed, done.still_cut), ((), ()))

    def test_a_netem_left_standing_raises(self):
        self.killed_app()
        self.fake.netem["s2-eth1"] = "replaced"         # replaced by somebody else
        with self.assertRaises(ndtwin.LinkNotRestored) as caught:
            self.k.restore_link(ENDS)
        err = caught.exception
        self.assertEqual(err.still_cut, ("s2-eth1",))
        self.assertEqual(err.restore.removed, ("s1-eth1",))
        self.assertEqual(self.fake.declared, set())
        self.assertIn("sudo tc qdisc del dev s2-eth1 parent 5:1", err.remedy)
        self.assertNotIn("k.restore_link", err.remedy)

    def test_an_unreadable_tree_raises(self):
        self.fake.script("POST", RECOVER, (200, fk.recovered(
            [fk.noop("s1-eth1"), fk.unreadable("s2-eth1")])))
        with self.assertRaises(ndtwin.LinkNotRestored) as caught:
            self.k.restore_link(ENDS)
        self.assertEqual(caught.exception.still_cut, ("s2-eth1",))
        self.assertEqual(caught.exception.remedy,
                         "k.restore_link(((1, 1), (2, 1))) again once the kernel can run tc there")

    def test_an_end_the_kernel_cannot_name_is_not_restored(self):
        self.fake.no_bridge.add(2)
        with self.assertRaises(ndtwin.LinkNotRestored) as caught:
            self.k.restore_link(ENDS)
        self.assertEqual(caught.exception.still_cut, (None,))
        self.assertIn("no bridge_name", caught.exception.remedy)
        self.assertNotIn("None", caught.exception.remedy)

    def test_after_a_kernel_restart_the_409_raises_and_changes_nothing(self):
        self.fake.netem.update({"s1-eth1": "foreign", "s2-eth1": "foreign"})
        with self.assertRaises(ndtwin.LinkNotRestored) as caught:
            self.k.restore_link(ENDS)
        err = caught.exception
        self.assertEqual((err.status, err.nothing_written, err.still_cut), (409, True, IFACES))
        self.assertEqual(len(self.posts()), 1)

    def test_an_unknown_outcome_is_link_not_restored_and_sent_once(self):
        self.fake.script("POST", RECOVER, None)
        with self.assertRaises(ndtwin.LinkNotRestored) as caught:
            self.k.restore_link(ENDS)
        self.assertIsNone(caught.exception.nothing_written)
        self.assertIsNone(caught.exception.still_cut)
        self.assertEqual(len(self.posts()), 1)


class SurfaceTest(unittest.TestCase):
    def test_the_names(self):
        self.assertTrue(issubclass(ndtwin.LinkNotRestored, ndtwin.NDTwinError))
        self.assertNotIn(ndtwin.LinkNotRestored, ndtwin.WriteError)
        self.assertEqual(ndtwin.Link(1, 1, 2, 1, True, 0.0, 0, 0, "ok").down_reason, None)


if __name__ == "__main__":
    unittest.main()
