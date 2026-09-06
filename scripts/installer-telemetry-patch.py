#!/usr/bin/env python3
"""
installer-telemetry-patch.py —— 宿主安装器 deb 的遥测移除补丁

功能：解包安装器 deb（ar + tar.xz），将其中上报函数体替换为直接返回
（安装完成/卸载两个纯上报点；下载功能保留，在线安装不受影响），重新打包。
输出与原 deb 仅此差异。

用法: installer-telemetry-patch.py <官方安装器.deb> <输出.deb> [上报函数名...]
默认上报函数: notify_install_finish notify_uninstall
"""
import io, sys, tarfile, hashlib

def read_ar(path):
    members = []
    with open(path, 'rb') as f:
        assert f.read(8) == b'!<arch>\n', '不是 ar 归档'
        while True:
            hdr = f.read(60)
            if len(hdr) < 60: break
            name = hdr[0:16].decode('ascii').strip()
            size = int(hdr[48:58].decode('ascii').strip())
            data = f.read(size)
            if size % 2: f.seek(1, 1)
            members.append((name, data))
    return members

def write_ar(path, members):
    out = [b'!<arch>\n']
    for name, data in members:
        hdr = f'{name:<16}{0:<12}{0:<6}{0:<6}{100644:<8}{len(data):<10}'.encode('ascii') + b'\x60\n'
        out.append(hdr); out.append(data)
        if len(data) % 2: out.append(b'\n')
    open(path, 'wb').write(b''.join(out))

def main(src, dst, fns):
    members = dict(read_ar(src))
    tar_name = next(k for k in members if k.startswith('data.tar'))
    mode = 'r:xz' if tar_name.endswith('.xz') else 'r:gz'
    comp = 'w:xz' if tar_name.endswith('.xz') else 'w:gz'

    with tarfile.open(fileobj=io.BytesIO(members[tar_name]), mode=mode) as tf:
        entries = [[m, tf.extractfile(m).read() if m.isreg() else b''] for m in tf.getmembers()]

    patched = 0
    for entry in entries:
        m, data = entry
        if m.name.endswith('utils.py'):
            text = data.decode('utf-8')
            for fn in fns:
                needle = f'def {fn}():'
                assert needle in text, f'未找到 {needle}'
                text = text.replace(needle, needle + '\n    return True  # telemetry disabled')
            entry[1] = text.encode('utf-8')
            m.size = len(entry[1])
            patched += len(fns)
    assert patched, '未找到可修改的上报函数'

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode=comp) as tf:
        for m, data in entries:
            info = tarfile.TarInfo(m.name)
            info.size = len(data); info.mode = m.mode; info.mtime = m.mtime
            info.uid = m.uid; info.gid = m.gid; info.uname = m.uname; info.gname = m.gname
            info.type = m.type; info.linkname = m.linkname
            if m.isreg(): tf.addfile(info, io.BytesIO(data))
            else: tf.addfile(info)
    members[tar_name] = buf.getvalue()

    write_ar(dst, [(k, members[k]) for k in ('debian-binary', 'control.tar.xz', 'data.tar.xz')
                   if k in members] + [(k, v) for k, v in members.items()
                                       if k not in ('debian-binary', 'control.tar.xz', 'data.tar.xz')])

    # 自校验
    chk = dict(read_ar(dst))
    with tarfile.open(fileobj=io.BytesIO(chk[tar_name]), mode=mode) as tf:
        for e in tf.getmembers():
            if e.name.endswith('utils.py'):
                t = tf.extractfile(e).read().decode('utf-8')
                got = t.count('telemetry disabled')
                assert got == len(fns), f'自校验失败: {got}'
    print(f'完成: {dst}（禁用 {patched} 个上报点）')
    print('sha256:', hashlib.sha256(open(dst, "rb").read()).hexdigest())

if __name__ == '__main__':
    src, dst = sys.argv[1], sys.argv[2]
    fns = sys.argv[3:] or ['notify_install_finish', 'notify_uninstall']
    main(src, dst, fns)
