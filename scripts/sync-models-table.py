#!/usr/bin/env python3
"""Keep portal/index.html's 支持机型 table identical to guide §1.2.

Both files wrap the table in:

    <!-- models-table -->
    ...
    <!-- /models-table -->

Edit the table in guide/recovery-guide.html only, then:

    scripts/sync-models-table.py          # copy guide → portal
    scripts/sync-models-table.py --check  # exit 1 if they differ

publish-pages.sh always copies before staging, so gh-pages cannot drift
even if the committed portal copy was forgotten.
"""
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GUIDE = os.path.join(ROOT, 'guide', 'recovery-guide.html')
PORTAL = os.path.join(ROOT, 'portal', 'index.html')
BEGIN = '<!-- models-table -->'
END = '<!-- /models-table -->'


def inner(path):
    s = io.open(path, encoding='utf-8', newline='').read()
    a = s.find(BEGIN)
    b = s.find(END)
    if a < 0 or b < 0 or b < a:
        sys.exit('%s 缺少 %s … %s 标记' % (
            os.path.relpath(path, ROOT), BEGIN, END))
    a += len(BEGIN)
    if s.find(BEGIN, a) >= 0:
        sys.exit('%s 有多于一处 %s' % (os.path.relpath(path, ROOT), BEGIN))
    return s, a, b, s[a:b]


def nl(s):
    return '\r\n' if '\r\n' in s else '\n'


def norm(s):
    return s.replace('\r\n', '\n')


def main():
    check = '--check' in sys.argv[1:]
    gs, ga, gb, g = inner(GUIDE)
    ps, pa, pb, p = inner(PORTAL)
    if norm(g) == norm(p):
        print('支持机型表一致')
        return 0
    if check:
        print('门户与教程的支持机型表不一致。', file=sys.stderr)
        print('改 guide/recovery-guide.html 1.2 那张表，再跑 '
              'scripts/sync-models-table.py', file=sys.stderr)
        return 1
    body = norm(g).replace('\n', nl(ps))
    io.open(PORTAL, 'w', encoding='utf-8', newline='').write(
        ps[:pa] + body + ps[pb:])
    print('已把教程 1.2 的支持机型表拷到门户')
    return 0


if __name__ == '__main__':
    sys.exit(main())
