const PubSub = require("@google-cloud/pubsub")

if (process.argv.length !== 3) {
  console.log("called with:", process.argv)
  throw new Error("Usage: node deploy.js REVISION")
}
const revision = process.argv[2]
const timeout = process.env.TIMEOUT ? Number(process.env.TIMEOUT) : 30000

setTimeout(() => {
  console.error("Timed out")
  process.exit(1)
}, timeout)

const deploy = async () => {
  const pubsub = new PubSub();
  const resultSubName = "deploy-ui-gcs-result-sub"
  const deployTopicName = "deploy-ui-gcs"

  console.log("Deploying revision", revision);
  console.log("Timing out after", timeout, "ms")

  const deployPublisher = pubsub.topic(deployTopicName).publisher()
  await deployPublisher.publish(Buffer.from(JSON.stringify({
    revision,
  })))

  console.log("Waiting for deployment results for revision", revision)

  const sub = pubsub.subscription(resultSubName)
  sub.on("message", message => {
    const event = JSON.parse(message.data.toString("utf8"))
    if (event.revision !== revision) return

    if (event.ok) {
      console.log("Deployment ok for revision", revision)
      message.ack()
      process.exit(0)
    } else {
      console.error("Deployment failed for revision", revision)
      process.exit(1)
    }
  })
}

deploy()
