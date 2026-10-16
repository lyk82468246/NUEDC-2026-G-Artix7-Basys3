"""Offline regression for drive-alias ownership and exception propagation."""
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

import vivado_paths


@unittest.skipUnless(vivado_paths.os.name == "nt", "Windows SUBST behavior")
class TestWorkspaceAlias(unittest.TestCase):
    def test_reused_alias_preserves_body_exception(self):
        root = Path(__file__).resolve().parents[2]
        with patch.object(Path, "exists", return_value=True), patch.object(
                vivado_paths.os.path, "samefile", return_value=True), patch.object(
                vivado_paths.subprocess, "run") as run:
            with self.assertRaisesRegex(InterruptedError, "cancelled capture"):
                with vivado_paths.workspace_alias(root):
                    raise InterruptedError("cancelled capture")
            run.assert_not_called()  # Do not remove another owner's mapping.

    def test_created_alias_removed_after_body_failure(self):
        root = Path(__file__).resolve().parents[2]
        with patch.object(Path, "exists", side_effect=[False] * len("VUTSRQPONMLKZYXW") + [False, True]), patch.object(
                vivado_paths.os.path, "samefile", return_value=True), patch.object(
                vivado_paths.subprocess, "run", return_value=Mock(returncode=0)) as run:
            with self.assertRaisesRegex(RuntimeError, "capture failed"):
                with vivado_paths.workspace_alias(root):
                    raise RuntimeError("capture failed")
            self.assertEqual(run.call_args_list[-1].args[0], ["subst", "V:", "/D"])

    def test_created_alias_not_removed_if_remapped(self):
        root = Path(__file__).resolve().parents[2]
        with patch.object(Path, "exists", side_effect=[False] * len("VUTSRQPONMLKZYXW") + [False, True]), patch.object(
                vivado_paths.os.path, "samefile", return_value=False), patch.object(
                vivado_paths.subprocess, "run", return_value=Mock(returncode=0)) as run:
            with vivado_paths.workspace_alias(root):
                pass
            self.assertEqual(run.call_count, 1)


if __name__ == "__main__":
    unittest.main()
