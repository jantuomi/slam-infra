const process = require("process")
const { deployPubSub } = require("./index")

if (process.argv.length !== 3) {
  console.log("called with:", process.argv)
  throw new Error("Usage: node trigger.js REVISION")
}
const arg = process.argv[2]

const json = JSON.stringify({ revision: arg })
const b64 = Buffer.from(json, "utf8").toString("base64")
deployPubSub({ data: b64 })
