from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .config import NightshiftConfig
from .runtime import RunContext


@dataclass(frozen=True)
class PlaybookRenderer:
    config: NightshiftConfig
    context: RunContext

    def render(
        self,
        playbook_name: str,
        *,
        task_file_path: str = "",
        finding_text: str = "",
    ) -> Path:
        template_path = self.config.playbooks_dir / f"{playbook_name}.md"
        if not template_path.is_file():
            raise FileNotFoundError(f"Playbook not found: {template_path}")

        rendered_path = self.context.rendered_dir / template_path.name
        content = template_path.read_text(encoding="utf-8")
        for placeholder, value in self._substitutions(
            task_file_path=task_file_path,
            finding_text=finding_text,
        ).items():
            content = content.replace(placeholder, value)
        rendered_path.write_text(content, encoding="utf-8")
        return rendered_path

    def _substitutions(
        self,
        *,
        task_file_path: str,
        finding_text: str,
    ) -> dict[str, str]:
        return {
            "{{DATE}}": self.context.run_date,
            "{{RUN_ID}}": self.context.run_id,
            "{{REPO_ROOT}}": str(self.config.repo_dir),
            "{{TASK_FILE_PATH}}": task_file_path,
            "{{COMMIT_WINDOW_DAYS}}": str(self.config.commit_window_days),
            "{{CONVERSATION_WINDOW_DAYS}}": str(self.config.conversation_window_days),
            "{{MAX_CONVERSATIONS}}": str(self.config.max_conversations),
            "{{RCFA_WINDOW_DAYS}}": str(self.config.rcfa_window_days),
            "{{MAX_FINDINGS}}": str(self.config.max_findings_per_detective),
            "{{MAX_TASK_FILES}}": str(self.config.max_task_files),
            "{{BASE_BRANCH}}": self.config.base_branch,
            "{{FINDING_TEXT}}": finding_text,
        }
