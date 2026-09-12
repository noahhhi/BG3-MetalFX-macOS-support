#!/usr/bin/env python3
"""Behavioral installation tests with isolated homes; never touch Steam/user files."""
import json
import shutil
import subprocess
import tempfile
from pathlib import Path
import xml.etree.ElementTree as ET
import sys

helper=Path(sys.argv[1]).resolve()
payload=Path(sys.argv[2]).resolve()
UUID='f3a7c1e2-9b4d-4e5a-8c6f-1d2e3f4a5b6c'
base_xml='<save><version major="4" minor="8" revision="0" build="700"/><region id="ModuleSettings"><node id="root"><children><node id="ModOrder"><children><node id="Module"><attribute id="UUID" value="11111111-1111-1111-1111-111111111111" type="guid"/></node></children></node><node id="Mods"><children><node id="ModuleShortDesc"><attribute id="UUID" value="11111111-1111-1111-1111-111111111111" type="guid"/><attribute id="Name" value="Unrelated mod" type="LSString"/></node></children></node></children></node></region></save>'

def run(home,action,ok=True,pay=payload):
    args=[str(helper),action,'--test-home',str(home)]
    if action=='install':args+=['--payload',str(pay)]
    p=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    assert (p.returncode==0)==ok,p.stdout
    return p.stdout

def fixture(home,option):
    vdf=home/'Library/Application Support/Steam/userdata/123/config/localconfig.vdf'
    ms=home/"Documents/Larian Studios/Baldur's Gate 3/PlayerProfiles/Public/modsettings.lsx"
    vdf.parent.mkdir(parents=True);ms.parent.mkdir(parents=True)
    entry='' if option is None else '"LaunchOptions" '+json.dumps(option)
    vdf.write_text('"UserLocalConfigStore" { "Software" { "Valve" { "Steam" { "apps" {\n'
      '"42" { "LaunchOptions" "before-other-game" }\n'
      '"1086940" { "LastPlayed" "123" '+entry+' }\n'
      '"99" { "LaunchOptions" "after-other-game" "Foo" "Bar" }\n'
      '} } } } } // retained comment\n')
    ms.write_text(base_xml)
    return vdf,ms

for option in [None,'--skip-launcher','env MY_FLAG=1 %command% --foo "quoted"','%command% -arg']:
    with tempfile.TemporaryDirectory(prefix='.bg3mf-test-') as d:
        home=Path(d);vdf,ms=fixture(home,option);original=vdf.read_text()
        run(home,'install');installed=vdf.read_text();run(home,'install');assert vdf.read_text()==installed
        for term in ['before-other-game','after-other-game','retained comment','"LastPlayed" "123"']:assert term in installed
        r=ET.parse(ms);assert len(r.findall(f'.//attribute[@id="UUID"][@value="{UUID}"]'))==2
        assert len(r.findall('.//node[@id="ModOrder"]'))==1
        # Later unrelated settings/mods must survive uninstall.
        vdf.write_text(vdf.read_text().replace('"Foo" "Bar"','"Foo" "ChangedLater"'))
        ms.write_text(ms.read_text().replace('Unrelated mod','Updated unrelated mod'))
        run(home,'uninstall')
        assert 'bg3mf_steam_launcher' not in vdf.read_text()
        assert 'ChangedLater' in vdf.read_text() and 'Updated unrelated mod' in ms.read_text()
        assert UUID not in ms.read_text()
        # Normalize whitespace left by removal of a newly inserted option.
        if option is not None:assert json.dumps(option) in vdf.read_text()
        assert not (home/'Library/Application Support/BG3MetalFX').exists()
        print('PASS roundtrip',repr(option))

with tempfile.TemporaryDirectory(prefix='.bg3mf-test-') as d:
    home=Path(d);vdf,ms=fixture(home,None);before=vdf.read_bytes()
    run(home,'install',ok=False,pay=home/'missing-payload');assert vdf.read_bytes()==before
    ms.write_text('<malformed>');run(home,'install',ok=False);assert vdf.read_bytes()==before
    print('PASS invalid payload / malformed XML leave configs unchanged')

with tempfile.TemporaryDirectory(prefix='.bg3mf-test-') as d:
    home=Path(d);vdf,ms=fixture(home,None);run(home,'install')
    vdf.write_text(vdf.read_text().replace('%command%','%command% --user-change'))
    before=vdf.read_bytes();run(home,'uninstall',ok=False)
    assert vdf.read_bytes()==before and (home/'Library/Application Support/BG3MetalFX/bg3mf_steam_launcher').exists()
    print('PASS changed BG3 options fail safely without removing launcher')

with tempfile.TemporaryDirectory(prefix='.bg3mf-test-') as d:
    home=Path(d);vdf,ms=fixture(home,'"/old dev/build/bg3mf_steam_launcher" %command% -keep')
    run(home,'install');assert '/old dev/' not in vdf.read_text();assert '-keep' in vdf.read_text()
    run(home,'uninstall');assert '-keep' in vdf.read_text();assert 'bg3mf_steam_launcher' not in vdf.read_text()
    print('PASS migrate v1 wrapper without restoring stale config backup')
with tempfile.TemporaryDirectory(prefix='.bg3mf-test-') as d:
    home=Path(d);vdf,ms=fixture(home,'/old/dev/build/bg3mf_steam_launcher %command%')
    run(home,'install');assert '/old/dev/' not in vdf.read_text()
    run(home,'uninstall');assert 'bg3mf_steam_launcher' not in vdf.read_text()
    print('PASS migrate unquoted v1 developer wrapper')
print('INSTALLER_TESTS PASS')
