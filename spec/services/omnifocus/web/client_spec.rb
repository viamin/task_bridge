# frozen_string_literal: true

require "rails_helper"

RSpec.describe Omnifocus::Web::Client do
  describe Omnifocus::Web::Client::Transport do
    let(:transport) { described_class.new(account: "account", password: "password") }
    let(:socket) { instance_double("SocketConnection", receive_json: "{}", send_json: nil) }

    before do
      allow(transport).to receive(:websocket).and_return(socket)
      allow(SecureRandom).to receive(:uuid).and_return("request-id")
    end

    it "keeps the add opcode separate from the created item kind" do
      transport.create_item(kind: :task, properties: { name: "Task title" })

      expect(socket).to have_received(:send_json).with(
        hash_including(op: "add", rid: "request-id", kind: "task", name: "Task title")
      )
    end
  end

  describe Omnifocus::Web::Client::Reference do
    let(:transport) { instance_double(Omnifocus::Web::Client::Transport) }
    let(:reference) do
      described_class.new(
        {
          id_: "task-1",
          name: "Original title",
          note: "Original note",
          defer_date: Time.zone.parse("2026-07-29 10:00:00 UTC")
        },
        transport:
      )
    end

    before do
      allow(transport).to receive(:update_item)
    end

    it "exposes transport-backed setters for syncable fields" do
      new_start_date = Time.zone.parse("2026-07-30 12:00:00 UTC")

      reference.note.set("Updated note")
      reference.name.set("Updated title")
      reference.defer_date.set(new_start_date)

      expect(transport).to have_received(:update_item).with(reference:, attributes: { note: "Updated note" })
      expect(transport).to have_received(:update_item).with(reference:, attributes: { name: "Updated title" })
      expect(transport).to have_received(:update_item).with(reference:, attributes: { defer_date: new_start_date })
      expect(reference.note.get).to eq("Updated note")
      expect(reference.name.get).to eq("Updated title")
      expect(reference.defer_date.get).to eq(new_start_date)
    end
  end
end
