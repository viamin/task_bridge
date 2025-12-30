# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Base::SyncItem", :full_options do
  # Create a concrete test class since Base::SyncItem is abstract
  let(:test_item_class) do
    Class.new(Base::SyncItem) do
      def attribute_map
        {}
      end

      def provider
        "TestService"
      end
    end
  end

  let(:asana_item_class) do
    Class.new(Base::SyncItem) do
      def attribute_map
        {}
      end

      def provider
        "Asana"
      end
    end
  end

  let(:omnifocus_item_class) do
    Class.new(Base::SyncItem) do
      def attribute_map
        {}
      end

      def provider
        "Omnifocus"
      end
    end
  end

  # Helper to create mock items with specific attributes
  def create_mock_item(item_class, attrs = {})
    sync_item = {
      "id" => attrs[:id] || SecureRandom.uuid,
      "title" => attrs[:title] || "Test Task",
      "completed" => attrs[:completed] || false,
      "notes" => attrs[:notes] || ""
    }
    item_class.new(sync_item: sync_item, options: options)
  end

  describe "#find_matching_item_in" do
    context "with empty collection" do
      let(:source_item) { create_mock_item(omnifocus_item_class, title: "Buy milk") }

      it "returns nil" do
        expect(source_item.find_matching_item_in([])).to be_nil
      end

      it "returns nil for nil collection" do
        expect(source_item.find_matching_item_in(nil)).to be_nil
      end
    end

    context "with ID matching" do
      let(:asana_id) { "asana-123" }
      let(:omnifocus_id) { "of-456" }

      context "when source has target's sync ID" do
        let(:source_item) do
          create_mock_item(omnifocus_item_class,
            id: omnifocus_id,
            title: "Buy milk",
            notes: "asana_id: #{asana_id}")
        end
        let(:target_item) do
          create_mock_item(asana_item_class,
            id: asana_id,
            title: "Buy milk")
        end

        it "matches by ID" do
          expect(source_item.find_matching_item_in([target_item])).to eq(target_item)
        end

        it "matches by ID even with different titles" do
          different_title_target = create_mock_item(asana_item_class,
            id: asana_id,
            title: "Get milk")
          expect(source_item.find_matching_item_in([different_title_target])).to eq(different_title_target)
        end
      end

      context "when target has source's sync ID" do
        let(:source_item) do
          create_mock_item(omnifocus_item_class,
            id: omnifocus_id,
            title: "Buy milk")
        end
        let(:target_item) do
          create_mock_item(asana_item_class,
            id: asana_id,
            title: "Buy milk",
            notes: "omnifocus_id: #{omnifocus_id}")
        end

        it "matches by ID" do
          expect(source_item.find_matching_item_in([target_item])).to eq(target_item)
        end
      end
    end

    context "with title matching" do
      context "when neither item has a sync ID (first-time sync)" do
        let(:source_item) do
          create_mock_item(omnifocus_item_class,
            id: "of-123",
            title: "Buy milk")
        end
        let(:target_item) do
          create_mock_item(asana_item_class,
            id: "asana-456",
            title: "Buy milk")
        end

        it "matches by title" do
          expect(source_item.find_matching_item_in([target_item])).to eq(target_item)
        end

        it "matches case-insensitively" do
          uppercase_target = create_mock_item(asana_item_class,
            id: "asana-456",
            title: "BUY MILK")
          expect(source_item.find_matching_item_in([uppercase_target])).to eq(uppercase_target)
        end

        it "does not match different titles" do
          different_target = create_mock_item(asana_item_class,
            id: "asana-456",
            title: "Get bread")
          expect(source_item.find_matching_item_in([different_target])).to be_nil
        end
      end

      context "when source already has a sync ID (is linked to another item)" do
        let(:source_item) do
          create_mock_item(omnifocus_item_class,
            id: "of-123",
            title: "Buy milk",
            notes: "asana_id: asana-old-999")  # Has a stale/different Asana ID
        end
        let(:target_item) do
          create_mock_item(asana_item_class,
            id: "asana-456",  # Different ID than what source has
            title: "Buy milk")
        end

        it "does NOT match by title to prevent stealing links" do
          expect(source_item.find_matching_item_in([target_item])).to be_nil
        end
      end

      context "when target already has a sync ID (is linked to another item)" do
        let(:source_item) do
          create_mock_item(omnifocus_item_class,
            id: "of-123",
            title: "Buy milk")
        end
        let(:target_item) do
          create_mock_item(asana_item_class,
            id: "asana-456",
            title: "Buy milk",
            notes: "omnifocus_id: of-old-999")  # Has a stale/different OmniFocus ID
        end

        it "does NOT match by title to prevent stealing links" do
          expect(source_item.find_matching_item_in([target_item])).to be_nil
        end
      end

      context "when both items have sync IDs pointing to different items" do
        let(:source_item) do
          create_mock_item(omnifocus_item_class,
            id: "of-123",
            title: "Buy milk",
            notes: "asana_id: asana-different")
        end
        let(:target_item) do
          create_mock_item(asana_item_class,
            id: "asana-456",
            title: "Buy milk",
            notes: "omnifocus_id: of-different")
        end

        it "does NOT match since both are linked elsewhere" do
          expect(source_item.find_matching_item_in([target_item])).to be_nil
        end
      end
    end

    context "shopping list scenario with repeated item titles" do
      let(:omnifocus_milk_new) do
        create_mock_item(omnifocus_item_class,
          id: "of-new-milk",
          title: "Buy milk")
        # No asana_id - this is a brand new task
      end

      let(:asana_milk_old_completed) do
        create_mock_item(asana_item_class,
          id: "asana-old-milk",
          title: "Buy milk",
          completed: true,
          notes: "omnifocus_id: of-old-milk")  # Linked to a previous OmniFocus task
      end

      let(:asana_milk_active) do
        create_mock_item(asana_item_class,
          id: "asana-active-milk",
          title: "Buy milk")
        # No omnifocus_id - never synced
      end

      it "new task does NOT match old completed task that is already linked" do
        expect(omnifocus_milk_new.find_matching_item_in([asana_milk_old_completed])).to be_nil
      end

      it "new task DOES match unlinked active task with same title" do
        expect(omnifocus_milk_new.find_matching_item_in([asana_milk_active])).to eq(asana_milk_active)
      end

      it "new task matches only the unlinked task when both exist in collection" do
        collection = [asana_milk_old_completed, asana_milk_active]
        expect(omnifocus_milk_new.find_matching_item_in(collection)).to eq(asana_milk_active)
      end
    end

    context "after items are synced and both have sync IDs" do
      let(:omnifocus_task) do
        create_mock_item(omnifocus_item_class,
          id: "of-123",
          title: "Review PR",
          notes: "asana_id: asana-456")
      end

      let(:asana_task) do
        create_mock_item(asana_item_class,
          id: "asana-456",
          title: "Review PR",
          notes: "omnifocus_id: of-123")
      end

      it "matches by ID even if title changes" do
        renamed_asana = create_mock_item(asana_item_class,
          id: "asana-456",
          title: "Review Pull Request",  # Different title
          notes: "omnifocus_id: of-123")

        expect(omnifocus_task.find_matching_item_in([renamed_asana])).to eq(renamed_asana)
      end
    end

    context "with multiple items having the same title" do
      let(:source_item) do
        create_mock_item(omnifocus_item_class,
          id: "of-new",
          title: "Buy milk")
      end

      let(:target_linked_to_other) do
        create_mock_item(asana_item_class,
          id: "asana-1",
          title: "Buy milk",
          notes: "omnifocus_id: of-other")
      end

      let(:target_unlinked) do
        create_mock_item(asana_item_class,
          id: "asana-2",
          title: "Buy milk")
      end

      it "only matches the unlinked item" do
        collection = [target_linked_to_other, target_unlinked]
        expect(source_item.find_matching_item_in(collection)).to eq(target_unlinked)
      end

      it "returns nil if all matching titles are already linked" do
        another_linked = create_mock_item(asana_item_class,
          id: "asana-3",
          title: "Buy milk",
          notes: "omnifocus_id: of-another")

        collection = [target_linked_to_other, another_linked]
        expect(source_item.find_matching_item_in(collection)).to be_nil
      end
    end
  end

  describe "#friendly_title_matches" do
    let(:source_item) { create_mock_item(omnifocus_item_class, title: "Buy milk") }

    it "matches identical titles" do
      target = create_mock_item(asana_item_class, title: "Buy milk")
      expect(source_item.friendly_title_matches(target)).to be true
    end

    it "matches case-insensitively" do
      target = create_mock_item(asana_item_class, title: "BUY MILK")
      expect(source_item.friendly_title_matches(target)).to be true
    end

    it "handles whitespace" do
      source_with_spaces = create_mock_item(omnifocus_item_class, title: "  Buy milk  ")
      target = create_mock_item(asana_item_class, title: "Buy milk")
      expect(source_with_spaces.friendly_title_matches(target)).to be true
    end

    it "does not match different titles" do
      target = create_mock_item(asana_item_class, title: "Get bread")
      expect(source_item.friendly_title_matches(target)).to be false
    end
  end
end
