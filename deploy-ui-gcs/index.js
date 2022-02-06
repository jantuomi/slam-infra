const { Storage } = require("@google-cloud/storage")
const PubSub = require("@google-cloud/pubsub")
const JSZip = require("jszip")

const storage = new Storage()
// const projectId = process.env.GCP_PROJECT || process.env.GCLOUD_PROJECT
const artifactBucketName = "gs://slam-lang-gh-artifacts"
const uiDeployBucketName = "gs://slam-lang-ui"

const pubsub = new PubSub();
const resultTopicName = "deploy-ui-gcs-result"
/**
 * Triggered from a message on a Cloud Pub/Sub topic.
 *
 * @param {!Object} event Event payload.
 * @param {!Object} context Metadata for the event.
 */
exports.deployPubSub = async (event, context) => {
  console.log("Received event:", event)

  const json = JSON.parse(Buffer.from(event.data, "base64").toString("utf8"))
  const revision = json.revision
  console.log("Parsed revision from event:", revision)
  const resultPublisher = pubsub.topic(resultTopicName).publisher()

  try {
    const archiveName = `ui-${revision}.zip`

    const artifactBucket = storage.bucket(artifactBucketName)
    const archiveFile = artifactBucket.file(archiveName)

    console.log("Downloading zip archive", archiveName)
    const zipData = await archiveFile.download()
    if (zipData.length !== 1) {
      throw new Error("zipData.length !== 1")
    }

    const zipContent = await JSZip.loadAsync(zipData[0])
    const zippedPaths = Object.keys(zipContent.files)

    console.log("Zipped content to deploy:", zippedPaths)

    const uiDeployBucket = storage.bucket(uiDeployBucketName)

    const prevFiles = await uiDeployBucket.getFiles()
    if (prevFiles.length !== 1) {
      throw new Error("prevFiles.length !== 1")
    }
    const prevFilePaths = prevFiles[0].map(f => f.name)
    console.log("Existing files:", prevFilePaths)

    const newFilePaths = []
    zippedPaths.forEach(filePath => {
      const zipFile = zipContent.files[filePath]
      if (zipFile.dir) return

      const deployFilePath = filePath.replace(/^dist\//, "")
      newFilePaths.push(deployFilePath)

      const newBucketFile = uiDeployBucket.file(deployFilePath)

      const nodeStream = zipFile.nodeStream()
      nodeStream.pipe(
        newBucketFile.createWriteStream({
          resumable: false,
          validation: false,
          contentType: "auto",
          metadata: {
            "Cache-Control": "no-store",
          },
        })
      )
    })
    console.log("Deployed new files:", newFilePaths)

    const filePathsToDelete = prevFilePaths
      .filter(prevFilePath => !newFilePaths.includes(prevFilePath))

    console.log("Obsolete files to delete:", filePathsToDelete)

    await Promise.all(
      filePathsToDelete.map(filePath =>
        uiDeployBucket.file(filePath).delete()
      )
    )

    console.log("Done!");

    await resultPublisher.publish(Buffer.from(JSON.stringify({
      revision,
      ok: true
    })))
  } catch (err) {
    console.error(err)
    await resultPublisher.publish(Buffer.from(JSON.stringify({
      revision,
      ok: false
    })))
    throw err
  }
};
