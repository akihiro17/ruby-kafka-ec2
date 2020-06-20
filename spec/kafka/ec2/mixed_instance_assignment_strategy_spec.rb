require "spec_helper"

RSpec.describe Kafka::EC2::MixedInstanceAssignmentStrategy do
  let(:cluster) do
    instance_double("Kafka::Cluster")
  end
  let(:strategy) do
    described_class.new(
      cluster: cluster,
      instance_family_weights: {
        "r4" => 1,
        "r5" => 1.08,
        "m5" => 1.13,
        "c5" => 1.25,
      },
      availability_zone_weights: ->() {
        {
          "ap-northeast-1a" => 1,
          "ap-northeast-1c" => 0.9,
        }
      },
    )
  end

  describe "#assign" do
    subject(:group_assignment) { strategy.assign(members: members, topics: ["topic"]) }

    let(:members) { member_id_to_metadata.keys }

    before do
      allow(cluster).to receive(:partitions_for) do
        partition_ids.map do |partition_id|
          instance_double("Kafka::Protocol::MetadataResponse::PartitionMetadata", partition_id: partition_id)
        end
      end
      strategy.member_id_to_metadata = member_id_to_metadata
    end

    context "with various instances" do
      let(:partition_ids) { (0 .. 499).to_a }
      let(:member_id_to_metadata) do
        {
          # Instances which have two members
          "0000-c5-a-0000" => "i-00000000000000000,c5.xlarge,ap-northeast-1a",
          "0001-m5-a-0000" => "i-00000000000000001,m5.xlarge,ap-northeast-1a",
          "0002-r5-a-0000" => "i-00000000000000002,r5.xlarge,ap-northeast-1a",
          "0003-r4-a-0000" => "i-00000000000000003,r4.xlarge,ap-northeast-1a",
          "0004-c5-c-0000" => "i-00000000000000004,c5.xlarge,ap-northeast-1c",
          "0005-m5-c-0000" => "i-00000000000000005,m5.xlarge,ap-northeast-1c",
          "0006-r5-c-0000" => "i-00000000000000006,r5.xlarge,ap-northeast-1c",
          "0007-r4-c-0000" => "i-00000000000000007,r4.xlarge,ap-northeast-1c",
          "0000-c5-a-0001" => "i-00000000000000000,c5.xlarge,ap-northeast-1a",
          "0001-m5-a-0001" => "i-00000000000000001,m5.xlarge,ap-northeast-1a",
          "0002-r5-a-0001" => "i-00000000000000002,r5.xlarge,ap-northeast-1a",
          "0003-r4-a-0001" => "i-00000000000000003,r4.xlarge,ap-northeast-1a",
          "0004-c5-c-0001" => "i-00000000000000004,c5.xlarge,ap-northeast-1c",
          "0005-m5-c-0001" => "i-00000000000000005,m5.xlarge,ap-northeast-1c",
          "0006-r5-c-0001" => "i-00000000000000006,r5.xlarge,ap-northeast-1c",
          "0007-r4-c-0001" => "i-00000000000000007,r4.xlarge,ap-northeast-1c",
          # Instances which have only one member
          "1000-c5-a-0000" => "i-00000000000001000,c5.xlarge,ap-northeast-1a",
          "1001-r4-a-0000" => "i-00000000000001001,r4.xlarge,ap-northeast-1a",
        }
      end

      it "assigns partitions to members considering their instance types and availability zones" do
        expect(group_assignment.values.flat_map { |a| a.topics["topic"] }.compact.uniq.size).to eq partition_ids.size

        {
          "0000-c5-a-0000" => 33,
          "0001-m5-a-0000" => 30,
          "0002-r5-a-0000" => 28,
          "0003-r4-a-0000" => 26,
          "0004-c5-c-0000" => 30,
          "0005-m5-c-0000" => 27,
          "0006-r5-c-0000" => 26,
          "0007-r4-c-0000" => 24,
          "0000-c5-a-0001" => 32,
          "0001-m5-a-0001" => 29,
          "0002-r5-a-0001" => 28,
          "0003-r4-a-0001" => 26,
          "0004-c5-c-0001" => 29,
          "0005-m5-c-0001" => 26,
          "0006-r5-c-0001" => 25,
          "0007-r4-c-0001" => 23,
          "1000-c5-a-0000" => 33,
          "1001-r4-a-0000" => 25,
        }.each do |member_id, parition_count|
          expect(group_assignment[member_id].topics["topic"].size).to eq parition_count
        end
      end
    end

    context "with only one partition" do
      let(:partition_ids) do
        [0]
      end

      let(:member_id_to_metadata) do
        {
          "0000-c5-a-0000" => "i-00000000000000000,c5.xlarge,ap-northeast-1a",
          "0001-m5-a-0000" => "i-00000000000000001,m5.xlarge,ap-northeast-1a",
        }
      end

      it "assigns the partition to the member with the highest capacity" do
        expect(group_assignment.values.flat_map { |a| a.topics["topic"] }.compact.uniq.size).to eq partition_ids.size

        expect(group_assignment["0000-c5-a-0000"].topics["topic"].size).to eq 1
        expect(group_assignment["0001-m5-a-0000"].topics["topic"]).to be_nil
      end
    end

    context "when the sum of (capacity * partition_count_per_capacity).round is less than the partition count" do
      let(:partition_ids) { (0 .. 9).to_a }
      let(:member_id_to_metadata) do
        {
          "0000-r4-a-0000" => "i-00000000000000000,r4.xlarge,ap-northeast-1a",
          "0000-r4-a-0001" => "i-00000000000000001,r4.xlarge,ap-northeast-1a",
          "0000-r4-a-0002" => "i-00000000000000002,r4.xlarge,ap-northeast-1a",
        }
      end

      it "assigns partitions to members without omissions" do
        expect(group_assignment.values.flat_map { |a| a.topics["topic"] }.compact.uniq.size).to eq partition_ids.size

        expect(group_assignment.keys).to match_array(["0000-r4-a-0000", "0000-r4-a-0001", "0000-r4-a-0002"])
        expect(group_assignment.values.map { |a| a.topics["topic"].size }).to match_array([4, 3, 3])
      end
    end
  end
end