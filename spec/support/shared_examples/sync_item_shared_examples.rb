# frozen_string_literal: true

RSpec.shared_examples "sync_item" do
  context "when creating a new item" do
    it "creates accessors for notes attributes" do
      item.send(:all_services, remove_current: true).each do |service|
        expect(item).to respond_to(:"#{service.underscore}_id")
        expect(item).to respond_to(:"#{service.underscore}_url")
      end
    end
  end
end
