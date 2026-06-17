const { Client } = require('ssh2');

const conn = new Client();
const host = '192.168.31.60';
const user = '545648820';

conn.on('ready', () => {
  console.log('[INFO] SSH 连接成功: ' + user + '@' + host);
  conn.exec('uname -a && whoami && hostname && pwd && date', (err, stream) => {
    if (err) {
      console.error('[ERROR] 执行命令失败:', err.message);
      conn.end();
      return;
    }
    stream.on('close', (code) => {
      console.log('[INFO] 命令执行完成，退出码:', code);
      conn.end();
    });
    stream.stdout.on('data', (data) => {
      process.stdout.write('[STDOUT] ' + data);
    });
    stream.stderr.on('data', (data) => {
      process.stdout.write('[STDERR] ' + data);
    });
  });
});

conn.on('error', (err) => {
  console.error('[ERROR] SSH 连接出错:', err.message);
  process.exit(1);
});

conn.connect({
  host: host,
  port: 22,
  username: user,
  password: process.env.SSH_PASSWORD,
  readyTimeout: 15000,
  strictVendor: false,
});
