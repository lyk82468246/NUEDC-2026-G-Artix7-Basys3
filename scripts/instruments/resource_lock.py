"""Nonblocking OS lease. Lock files remain; OS releases locks after a crash."""
from pathlib import Path
import os


class ResourceBusy(RuntimeError):
    pass


class ResourceLock:
    def __init__(self, path):
        self.path = Path(path)
        self.stream = None

    def acquire(self):
        if self.stream is not None:
            raise ResourceBusy(f"Lease already acquired: {self.path}")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        stream = self.path.open("a+b")
        # Windows locks a byte range; ensure byte zero exists before locking.
        stream.seek(0, 2)
        if stream.tell() == 0:
            stream.write(b"0")
            stream.flush()
        stream.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            stream.close()
            raise ResourceBusy(f"Resource is owned by another process: {self.path.name}") from error
        self.stream = stream
        return self

    def release(self):
        if self.stream is None:
            return
        stream, self.stream = self.stream, None
        try:
            stream.seek(0)
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream, fcntl.LOCK_UN)
        finally:
            stream.close()

    def __enter__(self):
        return self.acquire()

    def __exit__(self, *args):
        self.release()
