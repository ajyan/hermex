"""Run with: python3 -m unittest discover -s scripts/tests -v"""

import importlib.machinery
import importlib.util
from pathlib import Path
import sys
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "check-design-drift"
loader = importlib.machinery.SourceFileLoader("check_design_drift", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
drift = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = drift  # dataclasses look their module up while the class is built
loader.exec_module(drift)

DIFF = """\
diff --git a/HermesMobile/Features/Meals/MealsHomeView.swift b/HermesMobile/Features/Meals/MealsHomeView.swift
--- a/HermesMobile/Features/Meals/MealsHomeView.swift
+++ b/HermesMobile/Features/Meals/MealsHomeView.swift
@@ -10,0 +11,3 @@ struct MealsHomeView: View {
+        Text("Tonight").foregroundStyle(Color.hxTextSecondary)
+        Button("Recipe") {}.tint(.accentColor) // design-drift: allow neutral surface
+        Button("Retry") {}
@@ -40 +43 @@ struct MealsHomeView: View {
+        Divider()
diff --git a/HermesMobile/Config/HermexStyle.swift b/HermesMobile/Config/HermexStyle.swift
--- a/HermesMobile/Config/HermexStyle.swift
+++ b/HermesMobile/Config/HermexStyle.swift
@@ -1,0 +2 @@
+        .foregroundStyle(Color.hxTextSecondary)
"""


class AddedLinesTests(unittest.TestCase):
    def test_numbers_each_added_line_from_its_hunk(self):
        lines = drift.added_lines(DIFF)
        self.assertEqual([(p.rsplit("/", 1)[-1], n) for p, n, _ in lines],
                         [("MealsHomeView.swift", 11), ("MealsHomeView.swift", 12), ("MealsHomeView.swift", 13),
                          ("MealsHomeView.swift", 43), ("HermexStyle.swift", 2)])

    def test_a_deleted_file_adds_nothing(self):
        diff = "--- a/HermesMobile/X.swift\n+++ /dev/null\n@@ -1 +0,0 @@\n-Text(\"Retry\")\n"
        self.assertEqual(drift.added_lines(diff), [])


class FindingsTests(unittest.TestCase):
    def titles(self, gated):
        return [(rule.title, number) for rule, _, number in drift.findings(drift.added_lines(DIFF), gated)]

    def test_gated_run_checks_new_code_rules_and_skips_allowed_lines_and_config(self):
        self.assertEqual(sorted(self.titles(gated=True)),
                         [("hxTextSecondary as a text color", 11), ("retry copy", 13), ("system Divider", 43)])

    def test_whole_tree_rules_leave_out_new_code_rules(self):
        self.assertEqual(self.titles(gated=False), [("retry copy", 13)])

    def test_divider_rule_ignores_names_that_end_in_divider(self):
        lines = [("HermesMobile/Features/A.swift", 1, "PrepRowDivider()"),
                 ("HermesMobile/Features/A.swift", 2, "BrainHomeDivider()")]
        self.assertEqual(drift.findings(lines, gated=True), [])


if __name__ == "__main__":
    unittest.main()
