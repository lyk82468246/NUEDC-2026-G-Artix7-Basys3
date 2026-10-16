"""Work around Vivado's Windows Documents-path normalization using SUBST.

Reuse an exact existing workspace alias, otherwise create a free drive alias.
Only mappings created here and still pointing to this root are removed.
"""
from contextlib import contextmanager
import os
from pathlib import Path
import subprocess


@contextmanager
def workspace_alias(root):
    root = Path(root).resolve()
    if os.name != "nt":
        yield root
        return
    for letter in "VUTSRQPONMLKZYXW":
        alias = Path(f"{letter}:/")
        matches = False
        try:
            matches = alias.exists() and os.path.samefile(alias, root)
        except OSError:
            pass
        if matches:
            yield alias
            return
    for letter in "VUTSRQPONMLKZYXW":
        alias = Path(f"{letter}:/")
        if alias.exists():
            continue
        result = subprocess.run(["subst", f"{letter}:", str(root)], capture_output=True, timeout=5)
        if result.returncode:
            continue
        try:
            yield alias
        finally:
            if alias.exists() and os.path.samefile(alias, root):
                subprocess.run(["subst", f"{letter}:", "/D"], capture_output=True, timeout=5, check=True)
        return
    raise RuntimeError("No free/reusable Windows drive alias for Vivado")


def aliased(path, root, alias):
    resolved = Path(path).resolve()
    try:
        return (alias / resolved.relative_to(Path(root).resolve())).as_posix()
    except ValueError:
        return resolved.as_posix()
