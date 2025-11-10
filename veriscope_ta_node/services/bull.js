var express = require('express');
var router = express.Router();
var Queue = require('bull');
var Arena = require('bull-arena');
var Redis = require('ioredis');
var path = require('path');
var url = require('url');

var {REDIS_URI} = process.env;

var redis = new Redis(REDIS_URI);

// Parse REDIS_URI to extract host, port, password, and db for Arena
var parsedRedis = url.parse(REDIS_URI);
var redisConfig = {
  host: parsedRedis.hostname || 'redis',
  port: parseInt(parsedRedis.port) || 6379
};

// Extract password from auth (format: "user:password" or just "password")
if (parsedRedis.auth) {
  var authParts = parsedRedis.auth.split(':');
  redisConfig.password = authParts.length > 1 ? authParts[1] : authParts[0];
}

// Extract db from pathname (format: "/db-number")
if (parsedRedis.pathname && parsedRedis.pathname.length > 1) {
  var db = parseInt(parsedRedis.pathname.substring(1));
  if (!isNaN(db)) {
    redisConfig.db = db;
  }
}

var opts = {
  removeOnComplete: 100,
  removeOnFail: false,
  attempts: 10,
  limiter: {
    max: 100, // Limit queue to max 100 jobs per 1 seconds.
    duration: 1000,
    bounceBack: true // important
  },
  /*
  backoffStrategies: {
    jitter: function () {
      return 5000 + Math.random() * 500;
    }
  }
  */
};

// Configure bull arena UI - version 2.8.3 format
const arenaConfig = Arena({
  Bull: Queue,
  queues: [
    {name: "taSetAttestation", hostId: "main", redis: redisConfig},
    {name: "taSetAttestationStatusCheck", hostId: "main", redis: redisConfig},
    {name: "taEmptyTransaction", hostId: "main", redis: redisConfig},
    {name: "taEmptyTransactionStatusCheck", hostId: "main", redis: redisConfig},
    {name: "taTraceAndParseTransaction", hostId: "main", redis: redisConfig},
    {name: "taWebhookSend", hostId: "main", redis: redisConfig}
  ]
},
{
  basePath: '/arena',
  disableListen: true,
  useCdn: false
});


var service = {
  queue: {
    taSetAttestation: new Queue('taSetAttestation', REDIS_URI),
    taSetAttestationStatusCheck: new Queue('taSetAttestationStatusCheck', REDIS_URI),
    taEmptyTransaction: new Queue('taEmptyTransaction', REDIS_URI),
    taEmptyTransactionStatusCheck: new Queue('taEmptyTransactionStatusCheck', REDIS_URI),
    taTraceAndParseTransaction: new Queue('taTraceAndParseTransaction', REDIS_URI),
    taWebhookSend: new Queue('taWebhookSend', REDIS_URI)
  },
  arena: arenaConfig,
  redis: redis,
  opts: opts
};

service.queue.taSetAttestation.process(1, path.join(__dirname,'..','processors/taSetAttestation.js'));
service.queue.taSetAttestationStatusCheck.process(1, path.join(__dirname,'..','processors/taSetAttestationStatusCheck.js'));
service.queue.taEmptyTransaction.process(1, path.join(__dirname,'..','processors/taEmptyTransaction.js'));
service.queue.taEmptyTransactionStatusCheck.process(1, path.join(__dirname,'..','processors/taEmptyTransactionStatusCheck.js'));
service.queue.taTraceAndParseTransaction.process(1, path.join(__dirname,'..','processors/taTraceAndParseTransaction.js'));
service.queue.taWebhookSend.process(1, path.join(__dirname,'..','processors/taWebhookSend.js'));

module.exports = service;
