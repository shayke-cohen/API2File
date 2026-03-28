import type { BrowserHTTPTransport, BrowserHTTPTransportResponse } from "./interfaces.js";

class FetchTransportResponse implements BrowserHTTPTransportResponse {
  constructor(private readonly response: Response) {}

  get ok(): boolean {
    return this.response.ok;
  }

  get status(): number {
    return this.response.status;
  }

  get headers(): Headers {
    return this.response.headers;
  }

  async text(): Promise<string> {
    return this.response.text();
  }

  async json<T = unknown>(): Promise<T> {
    return this.response.json() as Promise<T>;
  }
}

export class FetchBrowserHTTPTransport implements BrowserHTTPTransport {
  async request(input: RequestInfo | URL, init?: RequestInit): Promise<BrowserHTTPTransportResponse> {
    return new FetchTransportResponse(await fetch(input, init));
  }
}
