const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const XLSX = require('xlsx');
const fs = require('fs');
const path = require('path');

const app = express();
const server = http.createServer(app);
const io = new Server(server);

const excelFile = path.join(__dirname, 'links.xlsx');

function loadLinks() {
  if (!fs.existsSync(excelFile)) {
    const wb = XLSX.utils.book_new();
    const ws = XLSX.utils.json_to_sheet([]);
    XLSX.utils.book_append_sheet(wb, ws, 'Links');
    XLSX.writeFile(wb, excelFile);
  }
  const wb = XLSX.readFile(excelFile);
  const ws = wb.Sheets['Links'];
  return XLSX.utils.sheet_to_json(ws);
}

function saveLink(link, wallet) {
  const data = loadLinks();
  data.push({ link, wallet, time: new Date().toISOString() });
  const ws = XLSX.utils.json_to_sheet(data);
  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, ws, 'Links');
  XLSX.writeFile(wb, excelFile);
}

io.on('connection', (socket) => {
  console.log('클라이언트 연결됨');
  socket.emit('initData', loadLinks());

  socket.on('newLink', ({ link, wallet }) => {
    saveLink(link, wallet);
    io.emit('newLink', { link, wallet, time: new Date().toISOString() });
  });
});

app.use(express.static('public'));

server.listen(3000, () => {
  console.log('서버 실행: http://localhost:3000');
});
