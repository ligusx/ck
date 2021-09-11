# 为知笔记docker
复制容器内的文件
docker cp wiz:/wiz/app/wizserver/node_modules/node-rsa/src/NodeRSA.js
复制文件到容器
docker cp /mnt/NodeRSA.js wiz:/wiz/app/wizserver/node_modules/node-rsa/src/NodeRSA.js
