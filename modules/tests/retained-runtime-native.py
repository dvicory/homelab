"""Run the exact retained helper/hook on ordinary native K3s, no opt-in."""
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

BASE = Path('/run/retained-production')
I = json.loads(Path('/etc/retained-production-inputs.json').read_text())
K = [I['k3s'], 'kubectl', '--request-timeout=5s']
CRI = [I['k3s'], 'crictl', '--timeout=10s']
ROOT = Path(I['root']['path'])
ENTRIES = {'first': {'id': 'fixture/first', 'uid': 1000, 'gid': 1000, 'mode': '0700'}}
REPORT = {'complete': False, 'scope': 'exact production helper/hook, ordinary native default runtime', 'cases': []}


def run(*args, data=None, check=True, timeout=15):
    p = subprocess.run([str(x) for x in args], input=data, text=True,
                       stdin=subprocess.DEVNULL if data is None else None,
                       capture_output=True, timeout=timeout)
    if check and p.returncode:
        raise RuntimeError(f'{args!r}: {p.returncode}: {(p.stdout+p.stderr)[-4096:]}')
    return p


def wait(label, fn, seconds=90):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = fn()
        if value:
            return value
        time.sleep(.5)
    raise TimeoutError(label)


def save(case, **data):
    REPORT['cases'].append({'case': case, **data})
    (BASE/'report.json').write_text(json.dumps(REPORT, indent=2)+'\n')
    print(json.dumps(REPORT['cases'][-1]), flush=True)


def apply(obj):
    return run(*K, 'apply', '-f', '-', data=json.dumps(obj)).stdout


def get(name):
    return json.loads(run(*K, 'get', 'pod', name, '-o', 'json').stdout)


def current(name):
    p = get(name)
    statuses = p.get('status', {}).get('containerStatuses', [])
    s = statuses[0] if statuses else {}
    if 'running' not in s.get('state', {}):
        return None
    cid = s['containerID'].split('://')[-1]
    detail = json.loads(run(*CRI, 'inspect', cid).stdout)
    return {'uid': p['metadata']['uid'], 'cid': cid, 'pid': detail['info']['pid'],
            'sandbox': detail['info']['sandboxID'], 'spec': detail['info']['runtimeSpec']}


def blocked(name, actual_hook=False):
    p = get(name)
    for s in p.get('status', {}).get('containerStatuses', []):
        w = s.get('state', {}).get('waiting', {})
        if w.get('reason') in ('CreateContainerError', 'RunContainerError', 'CrashLoopBackOff'):
            if not actual_hook or 'hook' in w.get('message', '').lower():
                return p
    if not actual_hook:
        events = json.loads(run(*K, 'get', 'events', '--field-selector',
                                'involvedObject.uid='+p['metadata']['uid'], '-o', 'json').stdout)['items']
        if any(e.get('reason') == 'FailedMount' for e in events):
            return p
    return None


def spec(host=False):
    root = copy.deepcopy(I['root'])
    if host:
        root['path'] = str(BASE/'backing'/'original')
    return {'version': 1, 'root': root, 'entries': copy.deepcopy(ENTRIES)}


def helper(operation, *, entry=None, host=False, succeeds=True):
    args = [I['helper'], operation, '--spec', '-']
    args += ['--entry', entry] if entry else ['--root']
    if operation != 'validate':
        args += ['--confirm', ENTRIES[entry]['id'] if entry else I['root']['id']]
    p = run(*args, data=json.dumps(spec(host)), check=succeeds)
    if not succeeds:
        assert p.returncode != 0, p.stdout
    return p


def inventory():
    apply({'apiVersion': 'v1', 'kind': 'ConfigMap', 'metadata': {
        'name': 'retained-directories', 'namespace': 'local-path-storage'},
        'data': {'directories.json': json.dumps(ENTRIES)}})


def pod(name, entry=None, external=False, root_view=False, init=False, sub_path=None):
    c = {'name': 'writer', 'image': I['imageName'], 'imagePullPolicy': 'Never',
         'resources': {'limits': {'memory': '32Mi'}}}
    p = {'automountServiceAccountToken': False, 'terminationGracePeriodSeconds': 1, 'containers': [c]}
    if entry or external:
        path = str(BASE/'external') if external else str(ROOT/entry)
        apply({'apiVersion': 'v1', 'kind': 'PersistentVolume', 'metadata': {'name': name}, 'spec': {
            'capacity': {'storage': '1Mi'}, 'volumeMode': 'Filesystem', 'accessModes': ['ReadWriteOnce'],
            'storageClassName': '', 'persistentVolumeReclaimPolicy': 'Retain', 'local': {'path': path},
            'nodeAffinity': {'required': {'nodeSelectorTerms': [{'matchExpressions': [{
                'key': 'kubernetes.io/hostname', 'operator': 'In', 'values': [I['nodeName']]}]}]}}}})
        apply({'apiVersion': 'v1', 'kind': 'PersistentVolumeClaim', 'metadata': {'name': name}, 'spec': {
            'volumeName': name, 'storageClassName': '', 'accessModes': ['ReadWriteOnce'],
            'resources': {'requests': {'storage': '1Mi'}}}})
        p['volumes'] = [{'name': 'data', 'persistentVolumeClaim': {'claimName': name}}]
        c['volumeMounts'] = [{'name': 'data', 'mountPath': '/data'}]
        if sub_path is not None:
            c['volumeMounts'][0]['subPath'] = sub_path
        c['command'] = ['/bin/sh', '-ec', 'echo x >> /data/starts; while :; do echo alive; sleep 1; done']
        p['securityContext'] = {'runAsUser': 1000, 'runAsGroup': 1000}
        c['securityContext'] = {'allowPrivilegeEscalation': False, 'capabilities': {'drop': ['ALL']}}
        if init:
            initial = copy.deepcopy(c)
            initial['name'] = 'initialize'
            initial['command'] = ['/bin/sh', '-ec', 'echo initialized >> /data/init']
            p['initContainers'] = [initial]
    elif root_view:
        p['volumes'] = [{'name': 'data', 'hostPath': {'path': str(ROOT), 'type': 'Directory'}}]
        c['volumeMounts'] = [{'name': 'data', 'mountPath': '/retained', 'readOnly': True}]
        c['command'] = ['/bin/sh', '-ec', 'test -d /retained/first; if touch /retained/forbidden; then exit 9; fi; sleep 3600']
    else:
        c['command'] = ['/bin/sh', '-c', 'while :; do echo alive; sleep 1; done']
    apply({'apiVersion': 'v1', 'kind': 'Pod', 'metadata': {'name': name}, 'spec': p})


def retire_publications(names):
    uids = [get(name)['metadata']['uid'] for name in names]
    run(*K, 'delete', 'pod', *names, '--wait=true', '--timeout=30s', timeout=40)
    wait('affected publications retired before restore', lambda: not any(
        '/pods/'+uid+'/'+kind+'/' in line
        for line in Path('/proc/self/mountinfo').read_text().splitlines()
        for uid in uids for kind in ('volumes', 'volume-subpaths')))


def restart(name, old):
    run(*CRI, 'stop', '--timeout', '1', old['cid'])
    def changed():
        c = current(name)
        return c if c and c['cid'] != old['cid'] else None
    c = wait(name+' cached restart', changed)
    assert c['uid'] == old['uid'] and c['sandbox'] == old['sandbox'], c
    return c


def dynamic_publication():
    run(*K, 'apply', '-f', str((Path(I['manifests'])/'local-path-provisioner').resolve()))
    run(*K, 'apply', '-f', I['manifests']+'/retained-storage/StorageClass-retained-local.yaml')
    run(*K, '-n', 'local-path-storage', 'rollout', 'status', 'deployment/local-path-provisioner',
        '--timeout=240s', timeout=250)
    entry = 'default.dynamic'
    ENTRIES[entry] = {'id': 'fixture/dynamic', 'uid': 1000, 'gid': 1000, 'mode': '0700'}
    inventory()
    apply({'apiVersion': 'v1', 'kind': 'PersistentVolumeClaim', 'metadata': {'name': 'dynamic'},
           'spec': {'storageClassName': 'retained-local', 'accessModes': ['ReadWriteOnce'],
                    'resources': {'requests': {'storage': '1Mi'}}}})
    apply({'apiVersion': 'v1', 'kind': 'Pod', 'metadata': {'name': 'dynamic'}, 'spec': {
        'automountServiceAccountToken': False, 'terminationGracePeriodSeconds': 1,
        'securityContext': {'runAsUser': 1000, 'runAsGroup': 1000},
        'volumes': [{'name': 'data', 'persistentVolumeClaim': {'claimName': 'dynamic'}}],
        'containers': [{'name': 'writer', 'image': I['imageName'], 'imagePullPolicy': 'Never',
            'command': ['/bin/sh', '-ec', 'echo dynamic >> /data/starts; sleep 3600'],
            'resources': {'limits': {'memory': '32Mi'}},
            'securityContext': {'allowPrivilegeEscalation': False, 'capabilities': {'drop': ['ALL']}},
            'volumeMounts': [{'name': 'data', 'mountPath': '/data'}]}]}})
    claim = json.loads(run(*K, 'get', 'pvc', 'dynamic', '-o', 'json').stdout)
    def refused():
        pods = json.loads(run(*K, '-n', 'local-path-storage', 'get', 'pods', '-o', 'json').stdout)['items']
        for candidate in pods:
            if not candidate['metadata']['name'].endswith(claim['metadata']['uid']):
                continue
            statuses = candidate.get('status', {}).get('containerStatuses', [])
            if any(status.get('state', {}).get('terminated', {}).get('exitCode') == 1 for status in statuses):
                assert any(mount['name'] == 'data' and mount.get('readOnly') is True
                           for mount in candidate['spec']['containers'][0]['volumeMounts'])
                return candidate
        return None
    refusal = wait('real selected controller refuses missing leaf without creating it', refused)
    assert not (ROOT/entry).exists()
    assert json.loads(run(*K, 'get', 'pvc', 'dynamic', '-o', 'json').stdout)['status']['phase'] == 'Pending'
    helper('provision', entry=entry)
    assert list((ROOT/entry).iterdir()) == []
    writer = wait('native selected dynamic controller publishes only explicit state', lambda: current('dynamic'), seconds=240)
    claim = json.loads(run(*K, 'get', 'pvc', 'dynamic', '-o', 'json').stdout)
    volume = json.loads(run(*K, 'get', 'pv', claim['spec']['volumeName'], '-o', 'json').stdout)
    assert volume['spec']['local']['path'] == str(ROOT/entry), volume
    assert (ROOT/entry/'starts').read_text() == 'dynamic\n'
    controller = json.loads(run(*K, '-n', 'local-path-storage', 'get', 'pods', '-o', 'json').stdout)
    save('selected-dynamic-controller-missing-provision-publication', refusal=refusal, claim=claim,
         volume=volume, controllerPods=controller, writer=writer)
    return writer


def main():
    BASE.mkdir(mode=0o700, exist_ok=True)
    source_checks = run(sys.executable, '-I', '-B', I['sourceChecks'], I['hook'])
    wait('API and native ServiceAccount', lambda: run(*K, 'get', 'serviceaccount', 'default', check=False).returncode == 0)
    apply({'apiVersion': 'v1', 'kind': 'Namespace', 'metadata': {'name': 'local-path-storage'}})
    inventory()
    Path('/srv/retained').mkdir(parents=True)
    run('mount', '-t', 'tmpfs', '-o', 'mode=0555,size=1M', 'retained-parent', '/srv/retained')
    ROOT.mkdir(mode=0)
    run('mount', '--make-rshared', '/srv/retained')
    run('mount', '-o', 'remount,ro', '/srv/retained')
    (BASE/'external').mkdir(mode=0o700)
    os.chown(BASE/'external', 1000, 1000)
    pod('unrelated')
    unrelated = wait('unrelated starts before retained provisioning', lambda: current('unrelated'))
    pod('external', external=True)
    external = wait('external PVC survives absent retained root', lambda: current('external'))
    (BASE/'external'/'nested').mkdir(mode=0o700)
    os.chown(BASE/'external'/'nested', 1000, 1000)
    pod('external-subpath', external=True, sub_path='nested')
    external_subpath = wait('unrelated real kubelet subPath survives absent retained root',
                            lambda: current('external-subpath'))
    apply({'apiVersion': 'v1', 'kind': 'Namespace', 'metadata': {'name': 'subpath-boundary'}})
    K.extend(['--namespace', 'subpath-boundary'])
    try:
        wait('foreign-namespace ServiceAccount', lambda: run(
            *K, 'get', 'serviceaccount', 'default', check=False).returncode == 0)
        pod('foreign-subpath', external=True, sub_path='nested')
        foreign_subpath = wait('unrelated local-PV subPath resolves outside the default namespace',
                               lambda: current('foreign-subpath'))
        run('mount', '-t', 'tmpfs', '-o', 'mode=0755,size=1M', 'retained-subpath-replacement', str(ROOT))
        (ROOT/'first'/'nested').mkdir(parents=True, mode=0o700)
        os.chown(ROOT/'first', 1000, 1000)
        os.chown(ROOT/'first'/'nested', 1000, 1000)
        pod('wrong-backing-subpath', 'first', sub_path='nested')
        wrong_source_refusal = wait('protected local-PV subPath refuses replacement backing',
                                   lambda: blocked('wrong-backing-subpath', actual_hook=True))
        assert not (ROOT/'first'/'nested'/'starts').exists()
        assert current('foreign-subpath')['cid'] == foreign_subpath['cid']
        retire_publications(['wrong-backing-subpath', 'foreign-subpath'])
        run('umount', str(ROOT))
    finally:
        REPORT['foreignNamespaceCleanup'] = 1
        try:
            remaining = json.loads(run(*K, 'get', 'pods', '-o', 'json').stdout)['items']
            if remaining:
                retire_publications([pod['metadata']['name'] for pod in remaining])
            REPORT['foreignNamespaceCleanup'] = 0
        finally:
            del K[-2:]
    (BASE/'backing').mkdir()
    run('mount', '-t', 'tmpfs', '-o', 'mode=0755,size=4M', 'retained-production-data', str(BASE/'backing'))
    assert not (BASE/'backing'/'original').exists()
    helper('validate', host=True, succeeds=False)
    helper('provision', host=True)
    assert list((BASE/'backing'/'original').iterdir()) == [BASE/'backing'/'original'/I['root']['marker']]
    run('mount', '--bind', str(BASE/'backing'/'original'), str(ROOT))
    run('mount', '--make-private', str(ROOT))
    helper('provision', entry='first')
    assert list((ROOT/'first').iterdir()) == []
    pod('first', 'first', init=True)
    first = wait('exact production hook allows init and app', lambda: current('first'))
    assert (ROOT/'first'/'init').read_text().splitlines() == ['initialized']
    first = restart('first', first)
    assert (ROOT/'first'/'starts').read_text().splitlines() == ['x', 'x']
    assert (ROOT/'first'/'init').read_text().splitlines() == ['initialized']
    (ROOT/'first'/'nested').mkdir(mode=0o700)
    os.chown(ROOT/'first'/'nested', 1000, 1000)
    pod('retained-subpath', 'first', sub_path='nested')
    retained_subpath = wait('retained real kubelet subPath is refused',
                            lambda: blocked('retained-subpath', actual_hook=True))
    assert not (ROOT/'first'/'nested'/'starts').exists()
    pod('root-view', root_view=True)
    view = wait('generic actual RO root publication helper', lambda: current('root-view'))
    assert not (ROOT/'forbidden').exists()
    frozen = {'k3s': run('systemctl', 'show', 'k3s', '-p', 'MainPID', '--value').stdout,
              'baseline': hashlib.sha256(Path('/run/homelab-retained-runtime/base.json').read_bytes()).hexdigest()}
    save('provision-init-app-cache-and-ro-root', root=I['root'], first=first, external=external,
         wrongBackingRefusal=wrong_source_refusal, foreignNamespaceWriter=foreign_subpath,
         externalSubpath=external_subpath, retainedSubpath=retained_subpath,
         sourceChecks=source_checks.stdout.strip(), frozen=frozen)
    dynamic = dynamic_publication()
    ledger = (ROOT/I['root']['marker']).read_bytes()
    (ROOT/'first').rename(ROOT/'first-held')
    (ROOT/'first').mkdir(mode=0o700)
    os.chown(ROOT/'first', 1000, 1000)
    helper('validate', entry='first', succeeds=False)
    helper('provision', entry='first', succeeds=False)
    before = (ROOT/'first-held'/'starts').read_bytes()
    run(*CRI, 'stop', '--timeout', '1', first['cid'])
    denied = wait('copied-coordinate replacement cached restart refused by real hook', lambda: blocked('first', True))
    assert denied['metadata']['uid'] == first['uid']
    assert list((ROOT/'first').iterdir()) == [] and (ROOT/'first-held'/'starts').read_bytes() == before
    (ROOT/'first').rmdir()
    (ROOT/'first-held').rename(ROOT/'first')
    helper('validate', entry='first')
    assert (ROOT/I['root']['marker']).read_bytes() == ledger
    recovered = wait('original inode return without identity reset', lambda: current('first'))
    assert recovered['uid'] == first['uid']
    save('replacement-refusal-original-return', samePodUID=recovered['uid'])
    began = time.monotonic()
    run('umount', '-l', str(ROOT))
    wait('native retained scopes retired', lambda: all(
        not Path('/proc/'+str(pid)).exists()
        for pid in (recovered['pid'], dynamic['pid'], view['pid'])), seconds=15)
    retirement = time.monotonic()-began
    wait('cached restart source loss denied', lambda: blocked('first', True))
    pod('new-missing', 'first')
    wait('new app source loss denied before write', lambda: blocked('new-missing'))
    assert current('unrelated')['cid'] == unrelated['cid'] and current('external')['cid'] == external['cid']
    assert current('external-subpath')['cid'] == external_subpath['cid']
    assert not (ROOT/'starts').exists()
    retire_publications(('first', 'new-missing', 'root-view', 'dynamic', 'retained-subpath'))
    run('mount', '--bind', str(BASE/'backing'/'original'), str(ROOT))
    run('mount', '--make-private', str(ROOT))
    helper('validate', entry='first')
    pod('first', 'first')
    restored = wait('only affected application recovers', lambda: current('first'))
    ENTRIES['second'] = {'id': 'fixture/second', 'uid': 1000, 'gid': 1000, 'mode': '0700'}
    inventory()
    helper('provision', entry='second')
    assert list((ROOT/'second').iterdir()) == []
    pod('second', 'second')
    second = wait('new declared app inherits exact protection without OS change', lambda: current('second'))
    assert frozen == {'k3s': run('systemctl', 'show', 'k3s', '-p', 'MainPID', '--value').stdout,
                      'baseline': hashlib.sha256(Path('/run/homelab-retained-runtime/base.json').read_bytes()).hexdigest()}
    began = time.monotonic()
    run('umount', '-l', str(ROOT))
    wait('recovered and newly declared scopes retire after source recovery', lambda: all(
        not Path('/proc/'+str(pid)).exists()
        for pid in (restored['pid'], second['pid'])), seconds=15)
    after_recovery_retirement = time.monotonic()-began
    assert current('unrelated')['cid'] == unrelated['cid'] and current('external')['cid'] == external['cid']
    assert current('external-subpath')['cid'] == external_subpath['cid']
    retire_publications(('first', 'second'))
    run('mount', '--bind', str(BASE/'backing'/'original'), str(ROOT))
    run('mount', '--make-private', str(ROOT))
    save('source-retirement-recovery-new-app', seconds=retirement,
         afterRecoverySeconds=after_recovery_retirement, restored=restored, added=second, frozen=frozen)
    REPORT['complete'] = True


status = 0
try:
    main()
except BaseException as error:
    REPORT['error'] = repr(error)
    REPORT['pods'] = run(*K, 'get', 'pods', '--all-namespaces', '-o', 'json', check=False).stdout
    REPORT['events'] = run(*K, 'get', 'events', '--all-namespaces', '-o', 'json', check=False).stdout
    print('PRODUCTION_FAILURE '+repr(error), flush=True)
    status = 1
finally:
    pod_cleanup = run(*K, 'delete', 'pod', '--all', '--wait=true', '--timeout=30s',
                      check=False, timeout=40).returncode
    REPORT['cleanup'] = {'pods': pod_cleanup or REPORT.get('foreignNamespaceCleanup', 0),
                         'source': run('umount', '-l', str(ROOT), check=False).returncode}
    if any(REPORT['cleanup'].values()):
        REPORT['complete'] = False
        status = 1
    (BASE/'report.json').write_text(json.dumps(REPORT, indent=2)+'\n')
    print('PRODUCTION_REPORT '+json.dumps(REPORT), flush=True)
sys.exit(status)
