import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
from urllib.error import HTTPError, URLError
from urllib.request import ProxyHandler, Request, build_opener
from uuid import uuid4


PLATFORM = 'linux/amd64'
SCHEMA_BASELINE = '20261120120000_review_code_rate_limit'
REVIEW_CODE = 'docker-smoke-code-01'
TOKEN_SECRET = 'billbandit-disposable-image-smoke-secret'
REVIEWER_ID = 'billbandit-review-account-v1'
HTTP = build_opener(ProxyHandler({}))


def docker(*args, log=None, check=True, timeout=75):
    if log is None:
        return subprocess.run(
            ['docker', *args], check=check, text=True, stdout=subprocess.PIPE, timeout=timeout,
        ).stdout.strip()
    with log.open('w') as output:
        subprocess.run(
            ['docker', *args], check=check, stdout=output, stderr=subprocess.STDOUT, timeout=timeout,
        )


def sql(container, database, statement):
    return docker(
        'exec', container, 'psql', '-XqAt', '-v', 'ON_ERROR_STOP=1', '-U', 'ci',
        '-d', database, '-c', statement, timeout=10,
    )


def migrations(container, database):
    rows = sql(container, database, '''
        SELECT migration_name, id
        FROM "_prisma_migrations"
        WHERE finished_at IS NOT NULL AND rolled_back_at IS NULL
        ORDER BY migration_name
    ''')
    return dict(row.split('|', 1) for row in rows.splitlines())


def wait_for(probe, description, seconds):
    deadline = time.monotonic() + seconds
    while True:
        result = probe()
        if result:
            return result
        if time.monotonic() >= deadline:
            raise RuntimeError(f'{description} did not become ready within {seconds}s.')
        time.sleep(0.2)


def port(container, internal):
    return docker('port', container, f'{internal}/tcp', timeout=10).removeprefix('127.0.0.1:')


def get_json(base, route, token=None, body=None):
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = f'Bearer {token}'
    payload = json.dumps(body).encode() if body is not None else None
    try:
        with HTTP.open(Request(base + route, payload, headers), timeout=5) as response:
            return response.status, json.load(response)
    except HTTPError as error:
        return error.code, None


def run_tool(command, directory, env, log):
    with log.open('w') as output:
        subprocess.run(
            command, cwd=directory, env=env, check=True, stdout=output,
            stderr=subprocess.STDOUT, timeout=65,
        )


def check_api(args, pg, network, database, schema, before, evidence):
    evidence.mkdir()
    app = f'{pg}-{database}'
    started = time.monotonic()
    try:
        docker(
            'run', '-d', '--platform', PLATFORM, '--name', app, '--network', network,
            '-p', '127.0.0.1::3000',
            '-e', f'DATABASE_URL=postgresql://ci:ci@{pg}:5432/{database}',
            '-e', f'BILLBANDIT_REVIEW_CODE={REVIEW_CODE}',
            '-e', f'MOBILE_JWT_SECRET={TOKEN_SECRET}',
            '-e', f'RAILWAY_GIT_COMMIT_SHA={args.revision}',
            '-e', 'RAILWAY_GIT_BRANCH=main', args.image,
        )
        base = f'http://127.0.0.1:{port(app, 3000)}'

        def health():
            if docker('inspect', '-f', '{{.State.Running}}', app, timeout=10) != 'true':
                raise RuntimeError(f'Image exited at startup in {database}.')
            try:
                status, body = get_json(base, '/api/health')
                return body if status == 200 else None
            except (URLError, TimeoutError, ConnectionError):
                return None

        body = wait_for(health, 'API image', 45)
        startup = round(time.monotonic() - started, 3)
        if body.get('status') != 'ok' or body.get('commit') != args.revision:
            raise RuntimeError('Health did not report the expected source revision.')
        (evidence / 'health.json').write_text(json.dumps(body, indent=2) + '\n')
        after = migrations(pg, database)
        (evidence / 'migrations.json').write_text(json.dumps({'before': before, 'after': after}, indent=2) + '\n')
        if list(after) != schema or not all(after[name] == identifier for name, identifier in before.items()):
            raise RuntimeError('Deployment did not apply the expected migrations or altered prior records.')
        if before and sql(pg, database, '''SELECT count(*) FROM "User" WHERE id = 'image-smoke-upgrade' ''') != '1':
            raise RuntimeError('Deployment did not preserve the pre-existing user.')

        status, enabled = get_json(base, '/api/mobile/auth/review-code')
        if status != 200 or enabled != {'enabled': True}:
            raise RuntimeError(f'Review code availability failed with HTTP {status}.')
        (evidence / 'review-availability.json').write_text(json.dumps(enabled) + '\n')
        unauthorized, _ = get_json(base, '/api/mobile/auth/me')
        if unauthorized != 401:
            raise RuntimeError(f'Unauthenticated mobile request returned HTTP {unauthorized}.')

        database_url = f'postgresql://ci:ci@127.0.0.1:{port(pg, 5432)}/{database}'
        env = {key: os.environ[key] for key in ('PATH', 'HOME', 'TMPDIR') if key in os.environ}
        env.update(
            CI='1', DATABASE_URL=database_url, DEV_DATABASE_URL=database_url, DEV_API_BASE=base,
            REVIEW_API_BASE_URL=base, MOBILE_JWT_SECRET=TOKEN_SECRET, DEV_MOBILE_JWT_SECRET=TOKEN_SECRET,
        )
        run_tool(
            [args.package_manager, 'run', 'review:reset', '--', '--confirm'],
            args.source, env, evidence / 'review-reset.log',
        )
        status, session = get_json(base, '/api/mobile/auth/review-code', body={'code': REVIEW_CODE})
        if status != 200 or not session.get('token'):
            raise RuntimeError(f'Local review sign-in failed with HTTP {status}.')
        status, identity = get_json(base, '/api/mobile/auth/me', token=session['token'])
        if status != 200 or identity['user']['id'] != REVIEWER_ID:
            raise RuntimeError(f'Reviewer identity was not authenticated. HTTP {status}.')

        api = args.source / 'apps/api'
        for name in ('Kabir', 'Zoya'):
            run_tool(
                ['bun', 'run', 'scripts/dev-data.ts', 'friend', name],
                api, env, evidence / f'dev-data-{name}.log',
            )
        run_tool(
            ['bun', 'run', 'scripts/any-member-delete-e2e.ts'],
            api, env, evidence / 'any-member-delete-e2e.log',
        )
        run_tool(
            [args.package_manager, 'run', 'review:teardown', '--', '--confirm'],
            args.source, env, evidence / 'review-teardown.log',
        )
        if sql(pg, database, f'''SELECT count(*) FROM "User" WHERE id = '{REVIEWER_ID}' ''') != '0':
            raise RuntimeError('Teardown left the reviewer account behind.')
        status, _ = get_json(base, '/api/mobile/auth/me', token=session['token'])
        if status != 401:
            raise RuntimeError(f'The stale reviewer session returned HTTP {status} after teardown.')
        result = {
            'startup_seconds': startup, 'health_http': 200, 'review_enabled': True,
            'review_sign_in_http': 200, 'authenticated_mobile_http': 200,
            'unauthenticated_mobile_http': unauthorized, 'stale_reviewer_http': status,
            'migrations_before': len(before), 'migrations_after': len(after),
            'replay': 'scripts/any-member-delete-e2e.ts', 'result': 'passed',
        }
        (evidence / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(f'{database}: {json.dumps(result)}', flush=True)
    finally:
        docker('logs', app, log=evidence / 'container.log', check=False, timeout=10)
        docker('rm', '-f', app, check=False, timeout=10)


def main(args):
    args.source = args.source.resolve()
    args.evidence = args.evidence.resolve()
    for path in (args.source, args.source / 'apps/api'):
        if any(not file.name.endswith(('.example', '.sample')) for file in path.glob('.env*')):
            raise RuntimeError('Use a checkout without local environment overrides.')
    args.evidence.mkdir(parents=True, exist_ok=True)
    pg = f'bb-image-{uuid4().hex[:10]}'
    network = f'{pg}-net'
    source = args.source / 'apps/api/prisma'
    schema = sorted(path.name for path in (source / 'migrations').iterdir() if path.is_dir())
    prefix = schema[:schema.index(SCHEMA_BASELINE) + 1]
    seed = args.evidence / 'seed-schema'
    (seed / 'migrations').mkdir(parents=True)
    shutil.copy2(source / 'schema.prisma', seed / 'schema.prisma')
    shutil.copy2(source / 'migrations/migration_lock.toml', seed / 'migrations')
    for name in prefix:
        shutil.copytree(source / 'migrations' / name, seed / 'migrations' / name)
    image = docker('image', 'inspect', args.image, '--format', '{{json .}}')
    data = json.loads(image)
    if (data['Os'], data['Architecture']) != ('linux', 'amd64'):
        raise RuntimeError('The smoke requires a linux/amd64 image.')
    (args.evidence / 'image.json').write_text(json.dumps({
        'revision': args.revision, 'id': data['Id'], 'bytes': data['Size'],
        'platform': PLATFORM, 'postgres_image': 'postgres:16-alpine',
        'package_manager': args.package_manager, 'baseline_migration': SCHEMA_BASELINE,
    }, indent=2) + '\n')
    docker('network', 'create', network)
    try:
        docker(
            'run', '-d', '--name', pg, '--network', network, '-p', '127.0.0.1::5432',
            '-e', 'POSTGRES_USER=ci', '-e', 'POSTGRES_PASSWORD=ci', 'postgres:16-alpine',
        )
        wait_for(lambda: postgres_ready(pg), 'Postgres', 30)
        for database in ('empty', 'upgraded'):
            docker('exec', pg, 'createdb', '-U', 'ci', database, timeout=10)
        if sql(pg, 'empty', "SELECT to_regclass('public._prisma_migrations') IS NULL") != 't':
            raise RuntimeError('The empty database already contains migration metadata.')
        check_api(args, pg, network, 'empty', schema, {}, args.evidence / 'empty')
        docker(
            'run', '--rm', '--platform', PLATFORM, '--network', network, '--entrypoint', 'node',
            '-e', f'DATABASE_URL=postgresql://ci:ci@{pg}:5432/upgraded',
            '--mount', f'type=bind,source={seed},target=/migration-baseline,readonly',
            args.seed_image or args.image, 'node_modules/prisma/build/index.js',
            'migrate', 'deploy', '--schema', '/migration-baseline/schema.prisma',
            log=args.evidence / 'seed-migrations.log',
        )
        before = migrations(pg, 'upgraded')
        if list(before) != prefix:
            raise RuntimeError('The upgraded database does not match the migration baseline.')
        sql(pg, 'upgraded', '''
            INSERT INTO "User" (id, email, "updatedAt")
            VALUES ('image-smoke-upgrade', 'image-smoke-upgrade@review.billbandit.invalid', CURRENT_TIMESTAMP)
        ''')
        check_api(args, pg, network, 'upgraded', schema, before, args.evidence / 'upgraded')
    finally:
        docker('logs', pg, log=args.evidence / 'postgres.log', check=False, timeout=10)
        docker('rm', '-f', '-v', pg, check=False, timeout=10)
        docker('network', 'rm', network, check=False, timeout=10)


def postgres_ready(container):
    return subprocess.run(
        ['docker', 'exec', container, 'pg_isready', '-q', '-h', '127.0.0.1', '-U', 'ci'],
        timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--image', required=True)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--seed-image')
    parser.add_argument('--package-manager', choices=('bun', 'npm'), default='bun')
    main(parser.parse_args())
