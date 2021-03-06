#! /usr/bin/env ruby
#
# elb-full-metrics
#
# DESCRIPTION:
#   Gets latency metrics from CloudWatch and puts them in Graphite for longer term storage
#
# OUTPUT:
#   metric-data
#
# PLATFORMS:
#   Linux
#
# DEPENDENCIES:
#   gem: fog
#   gem: sensu-plugin
#
# #YELLOW
# needs example command
# EXAMPLES:
#
#
# NOTES:
#   Returns latency statistics by default.  You can specify any valid ELB metric type, see
#   http://docs.aws.amazon.com/AmazonCloudWatch/latest/DeveloperGuide/CW_Support_For_AWS.html#elb-metricscollected
#
#   By default fetches statistics from one minute ago.  You may need to fetch further back than this;
#   high traffic ELBs can sometimes experience statistic delays of up to 10 minutes.  If you experience this,
#   raising a ticket with AWS support should get the problem resolved.
#   As a workaround you can use eg -f 300 to fetch data from 5 minutes ago.
#
# LICENSE:
#   Copyright 2013 Bashton Ltd http://www.bashton.com/
#   Released under the same terms as Sensu (the MIT license); see LICENSE
#   for details.
#

require 'rubygems' if RUBY_VERSION < '1.9.0'
require 'sensu-plugin/metric/cli'
require 'fog/aws'

class ELBMetrics < Sensu::Plugin::Metric::CLI::Graphite
  option :elbname,
         description: 'Name of the Elastic Load Balancer',
         short: '-n ELB_NAME',
         long: '--name ELB_NAME'

  option :scheme,
         description: 'Metric naming scheme, text to prepend to metric',
         short: '-s SCHEME',
         long: '--scheme SCHEME',
         default: ''

  option :fetch_age,
         description: 'How long ago to fetch metrics for',
         short: '-f AGE',
         long: '--fetch_age',
         default: 60,
         proc: proc(&:to_i)

  option :aws_access_key,
         short: '-a AWS_ACCESS_KEY',
         long: '--aws-access-key AWS_ACCESS_KEY',
         description: "AWS Access Key. Either set ENV['AWS_ACCESS_KEY'] or provide it as an option",
         required: true,
         default: ENV['AWS_ACCESS_KEY']

  option :aws_secret_access_key,
         short: '-k AWS_SECRET_KEY',
         long: '--aws-secret-access-key AWS_SECRET_KEY',
         description: "AWS Secret Access Key. Either set ENV['AWS_SECRET_KEY'] or provide it as an option",
         required: true,
         default: ENV['AWS_SECRET_KEY']

  option :aws_region,
         short: '-r AWS_REGION',
         long: '--aws-region REGION',
         description: 'AWS Region (such as eu-west-1).',
         default: 'us-east-1'

  def query_instance_region
    instance_az = nil
    Timeout.timeout(3) do
      instance_az = Net::HTTP.get(URI('http://169.254.169.254/latest/meta-data/placement/availability-zone/'))
    end
    instance_az[0...-1]
  rescue
    raise "Cannot obtain this instance's Availability Zone. Maybe not running on AWS?"
  end

  def run
    if config[:scheme] == ''
      graphitepath = "#{config[:elbname]}"
    else
      graphitepath = config[:scheme]
    end
    statistic_type = {
      'Latency' => 'Average',
      'RequestCount' => 'Sum',
      'UnHealthyHostCount' => 'Sum',
      'HealthyHostCount' => 'Sum',
      'HTTPCode_Backend_2XX' => 'Sum',
      'HTTPCode_Backend_4XX' => 'Sum',
      'HTTPCode_Backend_5XX' => 'Sum',
      'HTTPCode_ELB_4XX' => 'Sum',
      'HTTPCode_ELB_5XX' => 'Sum'
    }
    begin

      aws_region = (config[:aws_region].nil? || config[:aws_region].empty?) ? query_instance_region : config[:aws_region]
      cw = Fog::AWS::CloudWatch.new(
        aws_access_key_id: config[:aws_access_key],
        aws_secret_access_key: config[:aws_secret_access_key],
        region: aws_region
      )

      et = Time.now - config[:fetch_age]
      st = et - 60

      data = {}

      # #YELLOW
      config[:elbname].split(' ').each do |elbname| # rubocop:disable Style/Next
        statistic_type.each do |key, value|

          result = cw.get_metric_statistics('Namespace' => 'AWS/ELB',
                                            'MetricName' => key,
                                            'Dimensions' => [{
                                              'Name' => 'LoadBalancerName',
                                              'Value' => elbname
                                            }],
                                            'Statistics' => [value],
                                            'StartTime' => st.iso8601,
                                            'EndTime' => et.iso8601,
                                            'Period' => '60                                  ')
          r =  result.body['GetMetricStatisticsResult']['Datapoints']
          if r.count > 0
            data[key] = result.body['GetMetricStatisticsResult']['Datapoints'][0]
          end
        end

        unless data.nil?
          # We only return data when we have some to return
          data.each do |key, value|
            output graphitepath + ".#{elbname}.#{key}", value.to_a.last[1], value['Timestamp'].to_i
          end
        end
      end
    rescue => e
      critical "Error: exception: #{e}"
    end
    ok
  end
end
