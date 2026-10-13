"""Small UI-only CDP bridge; deliberately excludes network frame monitoring."""
import json
from pathlib import Path
import subprocess
import time
import base64


class BrowserProbe:
    def __enter__(self):
        host=Path(__file__).resolve().parents[1]
        self.child=subprocess.Popen([str(host/'build/environment/node/bin/node'),
            str(host/'scripts/browser_probe.cjs')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
        ready=json.loads(self.child.stdout.readline() or '{}')
        if not ready.get('ready'):
            self.child.terminate();self.child.wait(timeout=10)
            raise RuntimeError('Project browser probe could not attach')
        self.sequence=0;self.listeners={}
        return self

    def _read(self):
        """Drain small runtime exceptions while waiting for this command."""
        while True:
            value=json.loads(self.child.stdout.readline() or '{}')
            if value.get('event'):
                for callback in self.listeners.get(value['event'],[]):callback(value['message'])
                continue
            return value

    def on(self,event,callback):
        self.listeners.setdefault(event,[]).append(callback)

    def evaluate(self, expression, arg=None):
        """Invoke a supplied function using JSON arguments, never shell text."""
        self.sequence+=1
        code='('+expression+')('+('' if arg is None else json.dumps(arg))+')'
        self.child.stdin.write(json.dumps(dict(id=self.sequence,expression=code))+'\n');self.child.stdin.flush()
        result=self._read()
        if result.get('id')!=self.sequence or result.get('error'):
            raise RuntimeError(result.get('error','Browser probe disconnected'))
        return result.get('value')

    def system_info(self):
        """Read device/features on the browser session, without trace domains."""
        self.sequence+=1
        self.child.stdin.write(json.dumps(dict(id=self.sequence,method='SystemInfo.getInfo'))+'\n');self.child.stdin.flush()
        result=self._read()
        if result.get('id')!=self.sequence or result.get('error'):
            raise RuntimeError(result.get('error','Browser probe disconnected'))
        return result['value']

    def _page_command(self,method,params=None):
        self.sequence+=1
        self.child.stdin.write(json.dumps(dict(id=self.sequence,method=method,params=params or {}))+'\n');self.child.stdin.flush()
        result=self._read()
        if result.get('id')!=self.sequence or result.get('error'):
            raise RuntimeError(result.get('error','Browser probe disconnected'))
        return result.get('value')

    def reload(self,**options):
        """Reload only the attached workbench; keep other tabs and defaults."""
        self._page_command('Page.reload')
        deadline=time.monotonic()+30
        while time.monotonic()<deadline:
            try:
                if self.evaluate("()=>document.readyState!=='loading'&&!!document.querySelector('#capture-video')"):return
            except RuntimeError:pass
            time.sleep(.1)
        raise RuntimeError('Workbench reload did not complete')

    def screenshot(self,path,**options):
        """Optional post-measurement PNG; never a source-pixel or FPS proof."""
        value=self._page_command('Page.captureScreenshot',dict(format='png',captureBeyondViewport=True))
        Path(path).write_bytes(base64.b64decode(value['data']))

    def __exit__(self,*errors):
        self.child.stdin.close()
        try:self.child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.child.terminate();self.child.wait(timeout=10)
        self.child.stdout.close()
