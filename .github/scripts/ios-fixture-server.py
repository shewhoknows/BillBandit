import argparse
import os
import pathlib
import shutil
import signal
import socket
import subprocess
import threading

from api_qa_proxy import qa_proxy

root = pathlib.Path(__file__).resolve().parents[2]


def available_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def serve(directory):
    env_files = [path for folder in (root, root / "apps/api") for path in folder.glob(".env*")
                 if not path.name.endswith((".example", ".sample"))]
    if env_files:
        raise RuntimeError("Use a clean checkout without local API environment files.")
    pg_bin = pathlib.Path(subprocess.check_output(["pg_config", "--bindir"], text=True).strip())
    directory.mkdir(mode=0o700)
    try:
        data = directory / "postgres"
        port = available_port()
        upstream_port = available_port()
        pg = [str(pg_bin / "pg_ctl"), "-D", str(data), "-w"]
        subprocess.run(
            [str(pg_bin / "initdb"), "-D", str(data), "-U", "ci", "--auth=trust", "--no-sync"],
            check=True, stdout=subprocess.DEVNULL,
        )
        stop = threading.Event()
        signal.signal(signal.SIGTERM, lambda *_: stop.set())
        signal.signal(signal.SIGINT, lambda *_: stop.set())
        subprocess.run(
            [*pg, "-l", str(directory / "postgres.log"), "-o", f"-h 127.0.0.1 -p {port} -k ''", "start"],
            check=True,
        )
        try:
            with qa_proxy(upstream_port) as proxy_port:
                env = {name: os.environ[name] for name in ("PATH", "HOME", "LANG") if name in os.environ}
                env.update({
                    "CI": "1",
                    "BILLBANDIT_CI_E2E": "1",
                    "NEXT_TELEMETRY_DISABLED": "1",
                    "TEST_DATABASE_URL": f"postgresql://ci@127.0.0.1:{port}/postgres",
                    "START_VIETNAM_TRIP_SERVER": "1",
                    "VIETNAM_TRIP_UPSTREAM_PORT": str(upstream_port),
                    "VIETNAM_TRIP_BASE_URL": f"http://127.0.0.1:{proxy_port}",
                    "VIETNAM_TRIP_EVIDENCE_DIR": str(directory / "backend"),
                    "BILLBANDIT_UI_FIXTURE_DIR": str(directory),
                    "TSX_TSCONFIG_PATH": str(root / "apps/api/tsconfig.json"),
                })
                worker = subprocess.Popen(
                    ["node", "--import", "tsx", "apps/api/scripts/vietnam-trip-qa.ts"],
                    cwd=root, env=env, start_new_session=True,
                )
                try:
                    if worker.wait(timeout=100):
                        raise RuntimeError("The API fixture preparation failed.")
                    (directory / "ready").touch()
                    print("Three iOS fixtures are ready on the disposable API.", flush=True)
                    stop.wait()
                finally:
                    try:
                        os.killpg(worker.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    worker.wait()
        finally:
            subprocess.run([*pg, "-m", "fast", "stop"], check=True)
    finally:
        shutil.rmtree(directory)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=pathlib.Path)
    serve(parser.parse_args().directory.resolve())
