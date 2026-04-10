from __future__ import annotations

from pathlib import Path

import pytest

from nightshift.playbook import PlaybookRenderer
from nightshift.runtime import RunContext


def test_render_substitutes_placeholders(tmp_path: Path, config_factory) -> None:
    playbooks_dir = tmp_path / "playbooks"
    playbooks_dir.mkdir()
    (playbooks_dir / "sample.md").write_text(
        "\n".join(
            [
                "{{DATE}}",
                "{{RUN_ID}}",
                "{{REPO_ROOT}}",
                "{{TASK_FILE_PATH}}",
                "{{COMMIT_WINDOW_DAYS}}",
                "{{CONVERSATION_WINDOW_DAYS}}",
                "{{MAX_CONVERSATIONS}}",
                "{{RCFA_WINDOW_DAYS}}",
                "{{MAX_FINDINGS}}",
                "{{MAX_TASK_FILES}}",
                "{{BASE_BRANCH}}",
                "{{FINDING_TEXT}}",
            ]
        ),
        encoding="utf-8",
    )
    config = config_factory(
        repo_dir=tmp_path,
        extra_env={"NIGHTSHIFT_PLAYBOOKS_DIR": str(playbooks_dir)},
    )
    context = RunContext.create(config, dry_run=False, smoke=False)
    renderer = PlaybookRenderer(config=config, context=context)

    rendered_path = renderer.render(
        "sample",
        task_file_path="docs/tasks/open/example.md",
        finding_text="Line 1\nLine 2",
    )
    rendered_text = rendered_path.read_text(encoding="utf-8")

    assert "{{" not in rendered_text
    assert context.run_date in rendered_text
    assert context.run_id in rendered_text
    assert str(tmp_path) in rendered_text
    assert "docs/tasks/open/example.md" in rendered_text
    assert "Line 1\nLine 2" in rendered_text


def test_render_writes_to_rendered_dir(tmp_path: Path, config_factory) -> None:
    playbooks_dir = tmp_path / "playbooks"
    playbooks_dir.mkdir()
    (playbooks_dir / "sample.md").write_text("hello\n", encoding="utf-8")
    config = config_factory(
        repo_dir=tmp_path,
        extra_env={"NIGHTSHIFT_PLAYBOOKS_DIR": str(playbooks_dir)},
    )
    context = RunContext.create(config, dry_run=False, smoke=False)
    renderer = PlaybookRenderer(config=config, context=context)

    rendered_path = renderer.render("sample")

    assert rendered_path == context.rendered_dir / "sample.md"
    assert rendered_path.read_text(encoding="utf-8") == "hello\n"


def test_missing_playbook_raises(tmp_path: Path, config_factory) -> None:
    playbooks_dir = tmp_path / "playbooks"
    playbooks_dir.mkdir()
    config = config_factory(
        repo_dir=tmp_path,
        extra_env={"NIGHTSHIFT_PLAYBOOKS_DIR": str(playbooks_dir)},
    )
    context = RunContext.create(config, dry_run=False, smoke=False)
    renderer = PlaybookRenderer(config=config, context=context)

    with pytest.raises(FileNotFoundError):
        renderer.render("missing")
