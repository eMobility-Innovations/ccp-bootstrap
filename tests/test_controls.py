import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class Controls(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.target = self.home / 'managed.json'
        self.key = self.home / 'ingest-key'
        self.key.write_text('fixture-machine-key')
        self.env = dict(os.environ, FISZU_CONNECT_MANAGED_SETTINGS=str(self.target),
                        FISZU_CONNECT_CONFIG_DIR=str(self.home / 'config'),
                        FISZU_CONNECT_INGEST_KEY_FILE=str(self.key),
                        FISZU_CONNECT_CODEX_REQUIREMENTS=str(self.home / 'requirements.toml'))

    def run_cli(self, command, ok=True):
        result = subprocess.run([str(ROOT / 'fiszu-connect'), command], env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)
        return result

    def test_profile_pin_and_integrity(self):
        subprocess.run([str(ROOT / 'scripts/sync-connector-profile.sh'), '--check'], check=True)
        profile = json.loads((ROOT / 'profiles/connector-managed-settings.json').read_text())
        pin = json.loads((ROOT / 'profiles/PINNED').read_text())
        self.assertEqual(profile['profile_version'], pin['profile_version'])
        self.assertEqual(profile['env']['DISABLE_EXTRA_USAGE_COMMAND'], '1')

    def test_merge_noop_and_drift(self):
        self.target.write_text(json.dumps({'unrelated': {'keep': True}, 'env': {'KEEP': 'yes'}}))
        self.target.chmod(0o600)
        self.run_cli('apply-controls')
        self.assertEqual(self.target.stat().st_mode & 0o777, 0o600)
        actual = json.loads(self.target.read_text())
        self.assertEqual(actual['unrelated'], {'keep': True})
        self.assertEqual(actual['env']['KEEP'], 'yes')
        self.assertEqual(actual['env']['OTEL_EXPORTER_OTLP_ENDPOINT'], 'https://claude.fiszu.com')
        self.assertNotIn('profile_version', actual)
        helper = subprocess.run(actual['otelHeadersHelper'], shell=True, env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(helper.returncode, 0, helper.stderr)
        self.assertEqual(json.loads(helper.stdout), {'X-API-Key': 'fixture-machine-key'})
        before = self.target.stat().st_mtime_ns
        self.run_cli('apply-controls')
        self.assertEqual(self.target.stat().st_mtime_ns, before)
        self.assertIn('profile_version=1', self.run_cli('controls-status').stdout)
        del actual['env']['DISABLE_EXTRA_USAGE_COMMAND']
        self.target.write_text(json.dumps(actual))
        self.assertIn('DISABLE_EXTRA_USAGE_COMMAND', self.run_cli('controls-status', False).stdout)

    def test_missing_key_fails_without_writing(self):
        self.key.unlink()
        self.run_cli('apply-controls', False)
        self.assertFalse(self.target.exists())
        result = self.run_cli('otel-headers', False)
        self.assertNotIn('Authorization', result.stdout)

    def test_headers_use_only_machine_key(self):
        result = self.run_cli('otel-headers')
        self.assertEqual(json.loads(result.stdout), {'X-API-Key': 'fixture-machine-key'})

    def test_invalid_existing_json_preserved(self):
        self.target.write_text('{broken')
        self.run_cli('apply-controls', False)
        self.assertEqual(self.target.read_text(), '{broken')

    def test_codex_preserves_unrelated_and_detects_drift(self):
        binary = self.home / 'codex'
        binary.write_text('#!/bin/sh\nexit 0\n')
        binary.chmod(0o755)
        self.env['PATH'] = str(self.home) + os.pathsep + os.environ['PATH']
        target = self.home / 'requirements.toml'
        target.write_text('other = true\n[feature_requirements]\nkeep = true\nremote_control = true\n')
        self.run_cli('apply-controls')
        text = target.read_text()
        self.assertIn('other = true', text)
        self.assertIn('keep = true', text)
        self.assertIn('allow_remote_control = false', text)
        self.assertIn('remote_control = false', text)
        target.write_text(text.replace('allow_remote_control = false', 'allow_remote_control = true'))
        self.run_cli('controls-status', False)

    def test_installer_excludes_full_ccp(self):
        text = (ROOT / 'install-fiszu-connect.sh').read_text().lower()
        for forbidden in ('pangolin', 'lumen', 'setup.sh', 'repo-sync'):
            self.assertNotIn(forbidden, text)
        self.assertIn('apply-controls', text)


class ProfileGate(unittest.TestCase):
    def test_stale_copy_and_pinned_source(self):
        import shutil
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            vendor = root / 'vendor'
            shutil.copytree(ROOT / 'profiles', vendor / 'profiles')
            shutil.copytree(ROOT / 'scripts', vendor / 'scripts')
            ccp = root / 'ccp'
            (ccp / 'policy/profiles').mkdir(parents=True)
            source = ccp / 'policy/profiles/connector-managed-settings.json'
            source.write_bytes((ROOT / 'profiles/connector-managed-settings.json').read_bytes())
            (ccp / 'policy/codex-managed-config.toml').write_text(
                'allow_remote_control = false\nallowed_approval_policies = ["never"]\n'
                '[feature_requirements]\nremote_control = false\nremote_models = false\n')
            subprocess.run(['git', 'init', '-q', str(ccp)], check=True)
            subprocess.run(['git', '-C', str(ccp), 'add', '.'], check=True)
            subprocess.run(['git', '-C', str(ccp), '-c', 'user.name=Test', '-c',
                            'user.email=test@example.com', 'commit', '-qm', 'fixture'], check=True)
            script = str(vendor / 'scripts/sync-connector-profile.sh')
            subprocess.run([script, str(ccp)], check=True)
            subprocess.run([script, '--check', str(ccp)], check=True)
            self.assertIn('codex_source_sha256', json.loads((vendor / 'profiles/PINNED').read_text()))
            profile = json.loads(source.read_text())
            profile['env']['DISABLE_EXTRA_USAGE_COMMAND'] = '0'
            (vendor / 'profiles/connector-managed-settings.json').write_text(json.dumps(profile))
            result = subprocess.run([script, '--check', str(ccp)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            result = subprocess.run([script, '--check'], capture_output=True)
            self.assertNotEqual(result.returncode, 0)

    def test_installer_downloads_and_applies_controls(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            binary = home / 'mock-bin'
            binary.mkdir()
            curl = binary / 'curl'
            curl.write_text('#!/usr/bin/env python3\nimport shutil,sys\n'
                            'shutil.copyfile(sys.argv[2].removeprefix("file://"), sys.argv[4])\n')
            curl.chmod(0o755)
            claude = binary / 'claude'
            claude.write_text('#!/bin/sh\nexit 0\n')
            claude.chmod(0o755)
            key = home / 'key'
            key.write_text('fixture-key')
            env = dict(os.environ, HOME=str(home), PATH=str(binary) + os.pathsep + os.environ['PATH'],
                       FISZU_CONNECT_BASE_URL=ROOT.as_uri(),
                       FISZU_CONNECT_INGEST_KEY_FILE=str(key),
                       FISZU_CONNECT_CONFIG_DIR=str(home / 'config'),
                       FISZU_CONNECT_MANAGED_SETTINGS=str(home / 'managed.json'),
                       FISZU_CONNECT_CODEX_REQUIREMENTS=str(home / 'codex.toml'))
            result = subprocess.run(['bash', str(ROOT / 'install-fiszu-connect.sh')], env=env,
                                    capture_output=True, text=True, start_new_session=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            actual = json.loads((home / 'managed.json').read_text())
            self.assertEqual(actual['env']['DISABLE_EXTRA_USAGE_COMMAND'], '1')
            self.assertIn(str(home / '.local/bin/fiszu-connect'), actual['otelHeadersHelper'])


class PrivilegedMerge(unittest.TestCase):
    def test_elevated_merge_program_preserves_and_verifies(self):
        import runpy
        from unittest.mock import patch
        module = runpy.run_path(str(ROOT / 'fiszu-connect'))
        run = subprocess.run
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'managed.json'
            path.write_text('{"unrelated": true, "env": {"KEEP": "yes"}}')
            def sudo_fixture(command, **kwargs):
                self.assertEqual(command[0], 'sudo')
                return run(command[1:], **kwargs)
            with patch('os.geteuid', return_value=1000), patch('subprocess.run', side_effect=sudo_fixture):
                module['_apply_file'](path, {'env': {'DISABLE_EXTRA_USAGE_COMMAND': '1'}})
            self.assertEqual(json.loads(path.read_text()), {'unrelated': True, 'env': {
                'KEEP': 'yes', 'DISABLE_EXTRA_USAGE_COMMAND': '1'}})


if __name__ == '__main__':
    unittest.main()
