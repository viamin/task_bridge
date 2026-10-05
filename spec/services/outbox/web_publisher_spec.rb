# frozen_string_literal: true

require "rails_helper"

RSpec.describe Outbox::WebPublisher do
  let(:now) { Time.zone.parse("2026-10-05T12:00:00Z") }
  let(:config) do
    Outbox::WebPublisher::Config.resolve(
      "enabled" => true,
      "base_url" => "https://web.example.com",
      "api_key" => "secret",
      "batch_size" => 2
    )
  end
  let(:client) { instance_double(Outbox::WebPublisher::Client) }
  let(:keys) { [] }

  def create_entry(key, observed_at: now, next_retry_at: nil, status: "pending",
                   payload_version: OutboxEntry::PAYLOAD_VERSION)
    OutboxEntry.create!(
      idempotency_key: key,
      record_kind: "observation",
      event_type: "snapshot_seen",
      service_type: "test_service",
      service_instance: "test_service",
      external_id: key,
      observed_at:,
      payload: { contract_version: payload_version, item_key: "test_service:#{key}" },
      payload_version:,
      status:,
      attempts: 0,
      next_retry_at:
    )
  end

  def ok(results)
    Outbox::WebPublisher::Response.from_http(200, { results: }.to_json)
  end

  def accepted(key)
    { "record_kind" => "observation", "idempotency_key" => key, "status" => "accepted" }
  end

  def rejected(key, retryable:, error_code: "validation_error", message: "invalid row")
    { "record_kind" => "observation", "idempotency_key" => key, "status" => "rejected",
      "retryable" => retryable, "error_code" => error_code, "message" => message }
  end

  def publish
    described_class.run!(config:, client:, now:)
  end

  before do
    allow(client).to receive(:post_batch) do |batch|
      keys << batch.entries.map(&:idempotency_key)
      ok(batch.entries.map { |entry| accepted(entry.idempotency_key) })
    end
  end

  def capture_stdout
    original = $stdout
    captured = StringIO.new
    $stdout = captured
    yield
    captured.string
  ensure
    $stdout = original
  end

  describe "successful publication" do
    it "delivers every due row and reports counts" do
      entries = [create_entry("k1"), create_entry("k2", observed_at: now - 1.minute)]

      summary = publish

      expect(summary).to include(status: "published", batches: 1, delivered: 2, retryable: 0, failed: 0)
      entries.each { |entry| expect(entry.reload).to be_delivered }
      expect(keys).to eq([%w[k2 k1]])
    end

    it "reuses the same idempotency keys when a failed attempt is retried" do
      create_entry("k1")
      responses = [
        Outbox::WebPublisher::Response.from_http(503, '{"error": "down"}'),
        ok([accepted("k1")])
      ]
      allow(client).to receive(:post_batch) do |batch|
        keys << batch.entries.map(&:idempotency_key)
        responses.shift
      end

      expect(publish[:status]).to eq("incomplete")
      expect(described_class.run!(config:, client:, now: now + 2.hours)[:status]).to eq("published")

      expect(keys).to eq([["k1"], ["k1"]])
      expect(OutboxEntry.find_by(idempotency_key: "k1")).to be_delivered
    end
  end

  describe "batching" do
    it "sends multiple batches in FIFO order by observed_at" do
      create_entry("k1", observed_at: now - 2.minutes)
      create_entry("k2", observed_at: now - 1.minute)
      create_entry("k3", observed_at: now)

      summary = publish

      expect(summary).to include(batches: 2, delivered: 3)
      expect(keys).to eq([%w[k1 k2], ["k3"]])
    end

    it "skips rows whose retry backoff is not yet due" do
      create_entry("k1")
      create_entry("k-later", next_retry_at: now + 30.minutes)

      summary = publish

      expect(summary).to include(batches: 1, delivered: 1)
      expect(keys).to eq([["k1"]])
      expect(OutboxEntry.find_by(idempotency_key: "k-later")).to be_pending
    end

    it "sends each payload version in a batch with its matching contract version" do
      create_entry("v1", observed_at: now - 1.minute)
      create_entry("v2", payload_version: 2)
      versions = []
      allow(client).to receive(:post_batch) do |batch|
        versions << [batch.body[:contract_version], batch.body[:observations].map { |row| row["contract_version"] }]
        ok(batch.entries.map { |entry| accepted(entry.idempotency_key) })
      end

      summary = publish

      expect(summary).to include(batches: 2, delivered: 2)
      expect(versions).to eq([[1, [1]], [2, [2]]])
    end
  end

  describe "per-row partial success" do
    it "delivers accepted rows and preserves rejected ones for retry" do
      delivered = create_entry("k-accepted")
      retryable = create_entry("k-retryable")
      terminal = create_entry("k-terminal")
      allow(client).to receive(:post_batch) do |batch|
        rows = batch.entries.map do |entry|
          if entry.idempotency_key == "k-accepted"
            accepted(entry.idempotency_key)
          else
            rejected(entry.idempotency_key, retryable: entry.idempotency_key != "k-terminal")
          end
        end
        ok(rows)
      end

      summary = publish

      expect(summary).to include(status: "published", batches: 2, delivered: 1, retryable: 1, failed: 1)
      expect(delivered.reload).to be_delivered
      expect(retryable.reload).to be_pending
      expect(retryable.reload.next_retry_at).to be > now
      expect(terminal.reload).to be_failed
    end
  end

  describe "batch-level failures" do
    it "keeps every row pending with attempts and backoff on a retryable failure, then stops" do
      first = create_entry("k1")
      second = create_entry("k2", observed_at: now - 1.minute)
      third = create_entry("k3", observed_at: now - 2.minutes)
      allow(client).to receive(:post_batch) do |batch|
        keys << batch.entries.map(&:idempotency_key)
        Outbox::WebPublisher::Response.from_http(503, '{"error": {"message": "upstream down"}}')
      end

      summary = publish

      expect(summary).to include(status: "incomplete", stopped_reason: "http_503", retryable: 2, batches: 1)
      expect(keys).to eq([%w[k3 k2]])
      [first, second, third].each do |entry|
        row = entry.reload
        expect(row).to be_pending
        expect(row.attempts).to eq(entry == first ? 0 : 1)
      end
      expect(second.reload.next_retry_at).to be > now
      expect(third.reload.next_retry_at).to be > now
    end

    it "marks every row failed on a terminal failure such as an invalid API key" do
      entry = create_entry("k1")
      allow(client).to receive(:post_batch)
        .and_return(Outbox::WebPublisher::Response.from_http(401, '{"error": "invalid api key"}'))

      summary = publish

      expect(summary).to include(status: "incomplete", failed: 1)
      row = entry.reload
      expect(row).to be_failed
      expect(row.error_class).to eq("http_401")
      expect(row.error_message).to eq("invalid api key")
    end

    it "reduces network errors to a retryable failure without raising" do
      entry = create_entry("k1")
      allow(client).to receive(:post_batch)
        .and_return(Outbox::WebPublisher::Response.failure("Net::OpenTimeout", "timed out"))

      summary = publish

      expect(summary).to include(status: "incomplete", stopped_reason: "Net::OpenTimeout", retryable: 1)
      expect(entry.reload).to be_pending
    end
  end

  describe "gates" do
    it "does nothing when publication is disabled" do
      disabled_config = Outbox::WebPublisher::Config.resolve("enabled" => false)
      create_entry("k1")

      summary = described_class.run!(config: disabled_config, client:, now:)

      expect(summary).to include(status: "disabled", batches: 0)
      expect(client).not_to have_received(:post_batch)
      expect(OutboxEntry.find_by(idempotency_key: "k1")).to be_pending
    end

    it "does not send when enabled but not fully configured" do
      incomplete_config = Outbox::WebPublisher::Config.resolve("enabled" => true, "base_url" => "https://web.example.com")
      create_entry("k1")

      summary = described_class.run!(config: incomplete_config, client:, now:)

      expect(summary).to include(status: "not_configured", batches: 0)
      expect(client).not_to have_received(:post_batch)
      expect(OutboxEntry.find_by(idempotency_key: "k1")).to be_pending
    end
  end

  describe "dry run" do
    let(:dry_config) do
      Outbox::WebPublisher::Config.resolve(
        "enabled" => true, "dry_run" => true, "base_url" => "https://web.example.com"
      )
    end

    it "renders the batches that would be sent without touching delivery state" do
      create_entry("k1")
      create_entry("k2", observed_at: now - 1.minute)

      output = capture_stdout do
        summary = described_class.run!(config: dry_config, client:, now:)
        expect(summary).to include(status: "dry_run", batches: 1, rows: 2, delivered: 0)
      end

      parsed = JSON.parse(output)
      expect(parsed["dry_run"]).to be(true)
      expect(parsed["url"]).to eq("https://web.example.com#{Outbox::WebPublisher::Batch::ENDPOINT_PATH}")
      expect(parsed["body"]["contract_version"]).to eq(1)
      expect(parsed["body"]["observations"].map { |row| row["idempotency_key"] }).to contain_exactly("k2", "k1")
      expect(parsed["body"]["observations"]).to all(include("published_at"))
      expect(client).not_to have_received(:post_batch)
      expect(OutboxEntry.pending.count).to eq(2)
      expect(OutboxEntry.pending.map(&:attempts)).to all(eq(0))
    end

    it "works without any base URL or API key configured" do
      create_entry("k1")
      bare_config = Outbox::WebPublisher::Config.resolve("dry_run" => true)

      expect do
        described_class.run!(config: bare_config, client:, now:)
      end.to output(/dry_run/).to_stdout
    end
  end
end
