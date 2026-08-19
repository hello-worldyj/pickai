import { AwsClient } from "aws4fetch";

export interface B2Env {
  B2_KEY_ID: string;
  B2_APPLICATION_KEY: string;
  B2_BUCKET: string;
  B2_ENDPOINT: string;
}

function client(env: B2Env): AwsClient {
  return new AwsClient({
    accessKeyId: env.B2_KEY_ID,
    secretAccessKey: env.B2_APPLICATION_KEY,
    region: "eu-central-003",
    service: "s3",
  });
}

export async function fetchFromB2(env: B2Env, key: string): Promise<Response> {
  const url = `https://${env.B2_ENDPOINT}/${env.B2_BUCKET}/${key}`;
  return client(env).fetch(url, { method: "GET" });
}

export async function deleteFromB2(env: B2Env, key: string): Promise<void> {
  const url = `https://${env.B2_ENDPOINT}/${env.B2_BUCKET}/${key}`;
  const response = await client(env).fetch(url, { method: "DELETE" });
  if (!response.ok && response.status !== 404) {
    throw new Error(`B2 delete failed: ${response.status} ${await response.text()}`);
  }
}
