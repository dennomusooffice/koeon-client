"""Bounded stationary PTT input for explicitly authorized physical-device runs.

Unlike `input swipe`, this sends no repeated MOVE events. A successful shell
exit is NOT proof of gesture acceptance or audio delivery. Observe TALKING and
post-release READY independently; never attach UIAutomator during the hold.
"""
import math
import shlex
import subprocess
import time


def hold(adb, serial, x, y, seconds, observe, *, run=subprocess.run, sleep=time.sleep):
    """Observe once mid-hold; remote trap and host finally both release the touch.

    Caller must check the current testing window, unlocked READY screen, current
    bounds, and exclusive device ownership before calling. `observe` must be a
    passive screenshot/peer observation, not same-device UI automation.
    """
    if not serial or not isinstance(serial, str):
        raise ValueError('explicit device serial required')
    if any(isinstance(v, bool) or not isinstance(v, int) or not 0 <= v <= 16384 for v in (x, y)):
        raise ValueError('invalid coordinates')
    if isinstance(seconds, bool) or not isinstance(seconds, (int, float)) or not math.isfinite(seconds) or not 1 <= seconds <= 10:
        raise ValueError('hold must be finite, between 1 and 10 seconds')
    prefix = [adb, '-s', serial, 'shell']
    up = ['input', 'touchscreen', 'motionevent', 'UP', str(x), str(y)]
    down = ['input', 'touchscreen', 'motionevent', 'DOWN', str(x), str(y)]
    # The remote release remains scheduled even if the host observer fails.
    release = shlex.join(up)
    script = 'trap ' + shlex.quote(release) + ' EXIT; trap "exit 130" HUP INT TERM; '
    script += shlex.join(down) + ' && sleep ' + str(seconds)
    import concurrent.futures
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(run, prefix + ['sh', '-c', shlex.quote(script)],
                             check=True, capture_output=True, text=True, timeout=seconds + 5)
        try:
            sleep(seconds / 2)
            if future.done():
                future.result()
                raise RuntimeError('hold ended before observation')
            evidence = observe()
            future.result(timeout=seconds + 6)
            return {'status': 'OBSERVATION_REQUIRED', 'evidence': evidence,
                    'audioAcceptance': 'NOT_ESTABLISHED'}
        finally:
            run(prefix + up, check=True, capture_output=True, text=True, timeout=5)
