#!/usr/bin/env python3
"""Verify the packaged Spring/Lettuce blocking-read contract against isolated Redis.

Uses an already-built communication JAR and a cached Redis image. Never connects
to application Redis or starts a backend; removes its test container on exit.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

ROOT = Path(os.environ.get('MYSCOUTEE_PACKAGING_PROJECT_ROOT', Path.cwd()))
JAVA = r'''
import java.time.Duration;
import java.util.concurrent.*;
import org.springframework.data.redis.connection.lettuce.LettuceConnectionFactory;
import org.springframework.data.redis.connection.stream.*;
import org.springframework.data.redis.core.StringRedisTemplate;

class ChatBlockingProbe {
    public static void main(String[] args) throws Exception {
        var factory = new LettuceConnectionFactory("127.0.0.1", Integer.parseInt(args[0]));
        factory.afterPropertiesSet(); factory.start();
        var redis = new StringRedisTemplate(factory);
        var executor = Executors.newSingleThreadExecutor();
        try {
            if (factory.getClientConfiguration().getCommandTimeout().toSeconds() <= 10)
                throw new AssertionError("Client timeout must exceed the blocking wait");
            long idleStart = System.nanoTime();
            var empty = redis.opsForStream().read(StreamReadOptions.empty().block(Duration.ofSeconds(10)),
                    StreamOffset.create("isolated-chat-probe", ReadOffset.from("0-0")));
            long idleMs = (System.nanoTime() - idleStart) / 1_000_000;
            if ((empty != null && !empty.isEmpty()) || idleMs < 9500 || idleMs > 15000)
                throw new AssertionError("Unexpected empty blocking wait: " + idleMs);
            var read = executor.submit(() -> redis.opsForStream().read(
                    StreamReadOptions.empty().count(100).block(Duration.ofSeconds(10)),
                    StreamOffset.create("isolated-chat-probe", ReadOffset.from("0-0"))));
            long until = System.nanoTime() + TimeUnit.SECONDS.toNanos(3);
            boolean blocked = false;
            while (System.nanoTime() < until) {
                String clients = redis.execute((org.springframework.data.redis.core.RedisCallback<String>) c -> {
                    Object result = c.execute("CLIENT", "LIST".getBytes());
                    return result instanceof byte[] bytes ? new String(bytes, java.nio.charset.StandardCharsets.UTF_8)
                            : String.valueOf(result);
                });
                if (clients != null && clients.contains("cmd=xread")) { blocked = true; break; }
                Thread.sleep(20);
            }
            if (!blocked || read.isDone()) throw new AssertionError("Reader was not blocked");
            long start = System.nanoTime();
            redis.opsForValue().set("isolated-other-request", "ok");
            if (!"ok".equals(redis.opsForValue().get("isolated-other-request"))) throw new AssertionError();
            long otherMs = (System.nanoTime() - start) / 1_000_000;
            start = System.nanoTime();
            redis.opsForStream().add(StreamRecords.mapBacked(java.util.Map.of("payload", "probe"))
                    .withStreamKey("isolated-chat-probe"));
            var records = read.get(2, TimeUnit.SECONDS);
            long deliveryMs = (System.nanoTime() - start) / 1_000_000;
            if (records == null || records.size() != 1 || otherMs > 1000)
                throw new AssertionError("Other Redis operations were delayed");
            var waiting = executor.submit(() -> redis.opsForStream().read(
                    StreamReadOptions.empty().block(Duration.ofSeconds(10)),
                    StreamOffset.create("isolated-empty-shutdown", ReadOffset.from("0-0"))));
            Thread.sleep(100);
            waiting.cancel(true); executor.shutdownNow();
            if (!executor.awaitTermination(2, TimeUnit.SECONDS)) throw new AssertionError("Blocked reader did not stop");
            System.out.printf("PASS: empty wait=%d ms; concurrent SET/GET=%d ms; XADD wakeup=%d ms; interrupt shutdown passed%n",
                    idleMs, otherMs, deliveryMs);
        } finally { executor.shutdownNow(); factory.destroy(); }
    }
}
'''


def run(*args, timeout=30):
    result = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout.strip()


def main():
    name = f'myscoutee-chat-block-test-{os.getpid()}'
    image = os.environ.get('REDIS_TEST_IMAGE', 'redis:8.6.1-alpine')
    jar = ROOT / 'server/build/microservices/communication/libs/myscoutee-communication.jar'
    run('docker', 'image', 'inspect', image)  # missing cache must fail, never pull
    try:
        run('docker', 'run', '-d', '--pull=never', '--name', name, '--memory=64m', '--cpus=1',
            '-p', '127.0.0.1::6379', image, 'redis-server', '--save', '', '--appendonly', 'no')
        port = run('docker', 'port', name, '6379/tcp').rsplit(':', 1)[1]
        with tempfile.TemporaryDirectory(prefix='myscoutee-chat-block-test-') as directory:
            root = Path(directory)
            with zipfile.ZipFile(jar) as archive:
                for item in archive.namelist():
                    if item.startswith('BOOT-INF/lib/') and item.endswith('.jar'):
                        (root / Path(item).name).write_bytes(archive.read(item))
            source = root / 'ChatBlockingProbe.java'
            source.write_text(JAVA)
            print(run('java', '-Xmx128m', '-XX:ActiveProcessorCount=2', '--class-path', str(root / '*'),
                      str(source), port, timeout=45))
    finally:
        subprocess.run(['docker', 'rm', '-f', '-v', name], capture_output=True)


if __name__ == '__main__':
    main()
