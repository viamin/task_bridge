# frozen_string_literal: true

RSpec.shared_examples "sync_item" do
  context "when creating a new item" do
    let(:attributes) { item.class.send(:standard_attribute_map).merge(item.attribute_map).compact }

    it "creates accessors for item attributes" do
      attributes.each_key do |attribute_key|
        expect(item).to respond_to(attribute_key.to_sym)
      end
    end

    it "creates accessors for notes attributes" do
      item.send(:all_services, remove_current: true).each do |service|
        expect(item).to respond_to(:"#{service.underscore}_id")
        expect(item).to respond_to(:"#{service.underscore}_url")
      end
    end
  end
end
