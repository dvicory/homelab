from pathlib import Path
from tempfile import TemporaryDirectory

from transport import load


def check_loader():
    with TemporaryDirectory() as root:
        path = Path(root) / "fixture.yaml"
        for text in (
            "scenario: {fail: [must-remain], fail: [weaker]}\n",
            "scenario: {<<: {fail: [must-remain], fail: [weaker]}}\n",
            "scenario: {<<: [{fail: [must-remain], fail: [weaker]}]}\n",
            "scenario: {<<: {fail: [must-remain]}, <<: {fail: [weaker]}}\n",
        ):
            path.write_text(text)
            try:
                load(path)
            except ValueError:
                pass
            else:
                raise AssertionError("duplicate fixture key discarded a required failure")

        path.write_text(
            "scenario: {<<: &defaults {<<: {fail: [original], keep: retained}, fail: [selected]}}\n"
            "copy: *defaults\n"
        )
        selected = {"fail": ["selected"], "keep": "retained"}
        assert load(path) == {"scenario": selected, "copy": selected}
        path.write_text("scenario: {<<: {fail: [original]}, '<<': retained}\n")
        assert load(path)["scenario"] == {"fail": ["original"], "<<": "retained"}


if __name__ == "__main__":
    check_loader()
