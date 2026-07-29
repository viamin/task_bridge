# frozen_string_literal: true

require "rails_helper"

RSpec.describe Omnifocus::Web::Client do
  describe Omnifocus::Web::Client::Document do
    let(:transport) { instance_double(Omnifocus::Web::Client::Transport) }
    let(:document) { described_class.new(transport:) }

    it "memoizes flattened task lookups" do
      allow(transport).to receive(:load_lookup).with(container: "tasks").and_return([{ id_: "task-1", name: "Task 1" }])

      first_lookup = document.flattened_tasks
      second_lookup = document.flattened_tasks

      expect(first_lookup["task-1"].id_.get).to eq("task-1")
      expect(second_lookup).to equal(first_lookup)
      expect(transport).to have_received(:load_lookup).with(container: "tasks").once
    end
  end

  describe Omnifocus::Web::Client::Transport do
    let(:transport) { described_class.new(account: "account", password: "password") }
    let(:socket) { instance_double("SocketConnection", send_json: nil) }
    let(:ws_url) { "wss://sync.omnifocus.com/socket" }

    before do
      allow(transport).to receive(:resolve_instance).and_return({ "ws_url" => ws_url })
      allow(Omnifocus::Web::Client::SocketConnection).to receive(:new).and_return(socket)
      allow(SecureRandom).to receive(:uuid).and_return("request-id")
    end

    it "authenticates the websocket session before issuing requests" do
      allow(socket).to receive(:receive_json).and_return(
        { op: "pw?", kind: "account" }.to_json,
        { op: "session", key: "session-key" }.to_json,
        { op: "task=", rid: "request-id", items: [] }.to_json
      )
      expect(socket).to receive(:send_json).ordered.with(
        hash_including(op: "pw", rid: "request-id", kind: "account", value: "password")
      )
      expect(socket).to receive(:send_json).ordered.with(
        hash_including(op: "watch", rid: "request-id", in: "inbox", view: "all")
      )

      transport.load_collection(container: "inbox")

      expect(Omnifocus::Web::Client::SocketConnection).to have_received(:new).with(
        have_attributes(to_s: "wss://sync.omnifocus.com:443/socket"),
        protocols: ["v1.omnifocus.omnigroup.com"]
      )
    end

    it "creates inbox items as tasks targeted at the inbox container" do
      allow(socket).to receive(:receive_json).and_return(
        { op: "session", key: "session-key" }.to_json,
        { op: "task", rid: "request-id", oid: "task-1", id_: "task-1", name: "Task title" }.to_json
      )

      transport.create_item(kind: :inbox_task, properties: { name: "Task title" })

      expect(socket).to have_received(:send_json).with(
        hash_including(op: "task", rid: "request-id", in: "inbox", name: "Task title")
      )
    end

    it "creates child tasks inside the provided container" do
      allow(socket).to receive(:receive_json).and_return(
        { op: "session", key: "session-key" }.to_json,
        { op: "task", rid: "request-id", oid: "task-1", id_: "task-1", name: "Task title" }.to_json
      )
      parent = Omnifocus::Web::Client::Reference.new({ id_: "project-1" }, transport:)

      transport.create_item(kind: :task, properties: { name: "Task title" }, container: parent)

      expect(socket).to have_received(:send_json).with(
        hash_including(op: "task", rid: "request-id", in: "project-1", name: "Task title")
      )
    end

    it "rejects non-Omni websocket hosts before opening a socket" do
      allow(transport).to receive(:resolve_instance).and_return({ "ws_url" => "wss://attacker.test/socket" })

      expect do
        transport.load_collection(container: "inbox")
      end.to raise_error(Omnifocus::Web::Client::ConnectionError, /host is not allowed/)

      expect(Omnifocus::Web::Client::SocketConnection).not_to have_received(:new)
    end

    it "rejects insecure websocket schemes before opening a socket" do
      allow(transport).to receive(:resolve_instance).and_return({ "ws_url" => "ws://sync.omnifocus.com/socket" })

      expect do
        transport.load_collection(container: "inbox")
      end.to raise_error(Omnifocus::Web::Client::ConnectionError, /must use wss/)

      expect(Omnifocus::Web::Client::SocketConnection).not_to have_received(:new)
    end

    it "rejects websocket URLs with query parameters before opening a socket" do
      allow(transport).to receive(:resolve_instance).and_return({ "ws_url" => "wss://sync.omnifocus.com/socket?token=leak" })

      expect do
        transport.load_collection(container: "inbox")
      end.to raise_error(Omnifocus::Web::Client::ConnectionError, /must not include query parameters/)

      expect(Omnifocus::Web::Client::SocketConnection).not_to have_received(:new)
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
      allow(transport).to receive(:create_item).and_return({ id_: "child-1", name: "Child task" })
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

    it "creates child items through the transport" do
      child = reference.make(new: :task, with_properties: { name: "Child task" })

      expect(transport).to have_received(:create_item).with(
        kind: :task,
        properties: { name: "Child task" },
        container: reference
      )
      expect(child).to be_a(described_class)
      expect(child.id_.get).to eq("child-1")
    end

    it "supports folder project traversal with transport-backed nested references" do
      allow(transport).to receive(:create_item).and_return({ id_: "child-2", name: "Nested child" })
      folder = described_class.new(
        {
          id_: "folder-1",
          name: "Work",
          projects: [
            {
              id_: "project-1",
              name: "Launch",
              projects: [
                { id_: "project-2", name: "Nested" }
              ]
            }
          ]
        },
        transport:
      )

      direct_project = folder.projects["Launch"]
      nested_project = folder.flattened_projects["Nested"]
      child = nested_project.make(new: :task, with_properties: { name: "Nested child" })

      expect(direct_project.id_.get).to eq("project-1")
      expect(nested_project.id_.get).to eq("project-2")
      expect(transport).to have_received(:create_item).with(
        kind: :task,
        properties: { name: "Nested child" },
        container: nested_project
      )
      expect(child.id_.get).to eq("child-2")
    end
  end
end
