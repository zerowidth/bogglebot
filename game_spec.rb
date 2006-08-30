require 'game'
require 'rubygems'
require 'flexmock'
include Boggle

# ----- fixtures -----
#   i e a d r
#   s z n e d
#   n r o a c
#   a u e e s
#   p a d o o
def words
  # 2 players
  # 8 words total
  # 1 duplicate
  # 2 rejected (daen, dane (proper))
  # 5 words remaining
  { 'one' => ['deaden', 'dread', 'snap', 'daen', 'read'], 'two' => ['case', 'cased', 'snap', 'dane'] }
end
def add_words_to_game game
  words.each {|player, player_words| player_words.each { |word| game.add_word(player, word) } }
end

# ----- setup -----
module Notification
  attr_reader :observers
end
class Game
  attr_reader :state, :words, :found_words
  public :score # so scoring code can be verified
end

class Recorder
  attr_reader :calls
  def initialize
    @calls = {}
  end
  def record_call(method, *args)
    (@calls[method] ||= []) << args
  end
  def verified(*args); record_call(:verified, *args); end
end

class FindingState
  attr_reader :timeout, :words, :thread
end
class VerifyingState
  attr_reader :words
end
class VotingState
  attr_reader :votes
end
  

# ----- finding state specification -----

context "A new FindingState" do
  setup do 
    @state = FindingState.new 0.1, GameBoard.new(101)
  end
  
  specify "should handle add_words delegation by adding player words to internal word list" do
    @state.add_word('one', 'deaden').should_be nil
    @state.words.should_equal( {'one' => ['deaden']} )
  end
  
  specify "should return error when trying to add a word not on the board" do
    @state.add_word('one', 'deep').should_equal 'not on the board'
  end
  
  specify "should return error when trying to add an empty word" do
    @state.add_word('one', '').should_equal 'word too short'
  end
  
  specify "should return false when trying to add a 3-letter word (too short)" do
    @state.add_word('one', 'red').should_equal 'word too short'
  end
  
  specify "should trigger :times_up callback with word list after specified time has passed" do
    FlexMock.use('mock') do |mock|
      mock.should_receive(:times_up).with(Hash).once
      @state.add_observer mock, :times_up
      sleep(0.12)
    end
  end
  
  specify "internal timeout thread should not raise any exceptions" do
    lambda do
      @state.thread.join
    end.should_not_raise Exception
  end
  
end

# ----- verifying state specification -----

context "A new VerifyingState with words specified" do
  setup do
    @state = VerifyingState.new(words())
    @recorder = Recorder.new
    @state.add_observer @recorder, :verified
  end
  
  specify "should trigger the :verified callback after calling verify_words" do
    FlexMock.use('mock') do |mock|
    mock.should_receive(:verified).with(Hash).once
      @state.add_observer mock, :verified
      @state.verify_words
    end
  end
  
  specify "callback should include the final word list" do
    @state.verify_words
    call = @recorder.calls[:verified].first
    call.first.should_not_equal nil
    call.first[:words].should_equal( {"one"=>["deaden", "dread", 'read'], "two"=>["case", "cased"] } )
  end
  
  specify "callback should include the duplicates word list" do
    @state.verify_words
    call = @recorder.calls[:verified].first
    call.first[:duplicates].should_equal({'snap' => %w{one two}})
  end
  
  specify "callback should include the rejected words list" do
    @state.verify_words
    call = @recorder.calls[:verified].first
    call.first[:rejected].should_include ['daen', 'one', 'rejected by aspell']
  end
  
  specify "verification should reject proper nouns" do 
    @state.verify_words
    call = @recorder.calls[:verified].first
    call.first[:rejected].should_include ['dane', 'two', 'rejected by aspell, proper noun?']
  end

end

# ----- voting state specification -----

context "A new VotingState with a word and a list of two voters" do
  setup do
    @state = VotingState.new('word', 'one', ['one', 'two'])
  end
  
  specify "should have a word attribute containing the current word" do
    @state.word.should_equal 'word'
  end
  
  specify "should not have any votes recorded" do
    @state.votes.should_equal( {} )
  end
  
  specify "should accept a vote from any of the specified voters" do
    @state.add_vote('one', true)
    @state.votes.should_equal( {'one' => true} )
  end
  
  specify "should not accept a vote from someone who's not a specified voter" do
    @state.add_vote('three', true)
    @state.votes.should_be_empty
  end
  
  specify "should trigger :vote_complete callback with 'true' after two yes votes" do
    FlexMock.use('mock') do |mock|
      mock.should_receive(:vote_complete).once.with(true)
      @state.add_observer mock, :vote_complete
      @state.add_vote('one', true)
      @state.add_vote('two', true)
    end
  end
  
  specify "should trigger :vote_complete callback with 'false' after one no vote (50%)" do
    FlexMock.use('mock') do |mock|
      mock.should_receive(:vote_complete).once.with(false)
      @state.add_observer mock, :vote_complete
      @state.add_vote('one', false)
    end
  end
  
end

context "A new VotingState with a list of three voters" do
  setup do
    @state = VotingState.new('word', 'one', %w{one two three})
  end
  
  specify "should trigger :vote_complete callback with 'true' after two yes votes" do
    FlexMock.use('mock') do |mock|
      mock.should_receive(:vote_complete).once.with(true)
      @state.add_observer mock, :vote_complete
      @state.add_vote('one', true)
      @state.add_vote('two', true)
    end
  end
  
  specify "should trigger :vote_complete callback with 'false' after two no votes (>50%)" do
    FlexMock.use('mock') do |mock|
      mock.should_receive(:vote_complete).once.with(false)
      @state.add_observer mock, :vote_complete
      @state.add_vote('one', false)
      @state.add_vote('two', false)
    end
  end
  
  specify "should allow a player to change his vote if the callback hasn't been triggered yet" do
    FlexMock.use('mock') do |mock|
      mock.should_receive(:vote_complete).once.with(true)
      @state.add_observer mock, :vote_complete
      @state.add_vote('three', false)
      @state.add_vote('two', true)
      @state.add_vote('three', true) # should trigger callback with 'true'
    end
  end
  
  specify "should end the vote immediately if the person who typed the word votes no on it" do
    FlexMock.use('mock') do |mock|
      mock.should_receive(:vote_complete).once.with(false)
      @state.add_observer mock, :vote_complete
      @state.add_vote('one', false)
    end
  end

end

# ----- game specification -----

context "A new game" do
  setup do
    @game = Game.new
  end
  
  specify "should not be running" do
    @game.should_not_be_running
  end

  specify "should not set up a board" do
    @game.board.should_be_nil
  end
  
  specify "should not have a board id" do
    @game.board_id.should_be_nil
  end

  specify "should have a nil state" do
    @game.state.should_be nil
  end

  specify "should trigger :game_started callback with board id when started" do
    FlexMock.use('client') do |client|
      client.should_receive(:game_started).with(Integer).once
      @game.add_observer client, :game_started
      @game.start
    end
  end
  
  specify "should allow :board_id argument to start" do
    FlexMock.use('client') do |client|
      client.should_receive(:game_started).with(101).once
      @game.add_observer client, :game_started
      @game.start :board_id => 101
    end
    @game.board.should_equal %w{
      i e a d r
      s z n e d
      n r o a c
      a u e e s
      p a d o o
    }
    @game.board_id.should_equal 101
  end
  
  specify "should allow :game_length argument and initialize the finding state with the specified length" do
    FlexMock.use('client') do |client|
      client.should_receive(:game_started).with(Integer).once
      @game.add_observer client, :game_started
      @game.start :game_length => 123 # seconds
    end
    @game.state.should_be_instance_of FindingState
    @game.state.timeout.should_be 123
  end
  
  specify "should return correct scores for given words (private method)" do
    @game.score(['']).should_equal 0
    @game.score(['four']).should_equal 1
    @game.score(['fieve']).should_equal 2
    @game.score(['sixsix']).should_equal 3
    @game.score(['xsevenx']).should_equal 5
    @game.score(['longlong']).should_equal 11
    @game.score(['four','four']).should_equal 2
  end
  
end

context "A started game" do
  setup do
    @game = Game.new
    @game.start :game_length => 0.2, :board_id => 101
    
    @good_words = {'one' => %w{deaden dread}, 'two' => %w{case cased} }
    @bad_words = {'one' => %w{daen dread}, 'two' => %w{case cased} }
  end
  
  specify "should be running" do
    @game.should_be_running
  end
  
  specify "should cancel game after cancel call" do
    @game.cancel
    @game.should_not_be_running
  end
  
  specify "should ignore a second start call" do
    board = @game.board
    @game.start :board_id => 123
    @game.board.should_equal board
  end
  
  specify "should be in the FindingState state" do
    @game.state.should_be_instance_of FindingState
  end
    
  specify "should be an observer for times_up callback on FindingState" do
    @game.state.observers[:times_up].should_not_be_nil
    @game.state.observers[:times_up].should_include @game
  end
  
  specify "should trigger :times_up callback after receiving times_up callback from state" do
    FlexMock.use('mock') do |mock|
      mock.should_receive(:times_up).once
      @game.add_observer mock, :times_up
      @game.times_up({})
    end
  end
  
  specify "should pass add_words call on to the state" do
    @game.add_word('one', 'dread')
    @game.state.words.should_include 'one'
    @game.state.words['one'].should_include 'dread'
  end
  
  specify "should verify words and trigger :verified callback with duplicates, rejected count, and total word count"+
  " after receiving times_up callback" do
    FlexMock.use('mock') do |mock|
      mock.should_receive(:verified).once.and_return { |arg| @arg = arg }  
      @game.add_observer mock, :verified
      @game.times_up(words())
    end
    @arg.should_equal :total => 8, :rejected => 2, :duplicates => {'snap' => %w{one two}}
  end
  
  specify "should be in nil state after times_up callback with 'good' word list" do
    @game.times_up( @good_words )
    @game.state.should_be_nil
  end
  
  specify "should trigger :game_over callback after times_up with 'good' word list" do
    FlexMock.use('mock') do |mock|
      mock.should_receive(:game_over).once
      @game.add_observer mock, :game_over
      @game.times_up( @good_words )
    end
  end
  
  specify "should no longer be running after :game_over callback" do
    @game.should_be_running
    @game.times_up( @good_words )
    @game.should_not_be_running
  end
  
  specify "should no longer be running after times_up with no words" do
    @game.should_be_running
    @game.times_up({})
    @game.should_not_be_running
  end
  
  specify "should call :game_over callback even when no words are added" do
    FlexMock.use('mock') do |mock|
      mock.should_receive(:game_over).once.and_return { |arg| @arg = arg }
      @game.add_observer mock, :game_over
      @game.state.thread.join
    end
    @arg.should_equal []
  end

end

context "A running game with words added (two of which require votes)" do
  setup do
    @game = Game.new
    @game.start :game_length => 0.1, :board_id => 101
    add_words_to_game @game
  end
  
  specify "should be in VotingState after finding state ends (times_up)" do
    @game.state.thread.join
    @game.state.should_be_instance_of VotingState
  end
  
  specify "should be an observer for :vote_complete callback on VotingState" do
    @game.state.thread.join
    @game.state.observers[:vote_complete].should_not_be_nil
    @game.state.observers[:vote_complete].should_include @game
  end
  
  specify "should trigger :vote_required callback for 'daen' after times_up" do
    FlexMock.use('mock') do |mock|
      mock.should_receive(:vote_required).once.with('daen', 'one', 'rejected by aspell')
      @game.add_observer mock, :vote_required
      @game.state.thread.join
    end
  end
  
  specify "should trigger :vote_required callback for 'dane' after receiving :vote_complete callback" do
    FlexMock.use('mock') do |mock|
      mock.should_receive(:vote_required).twice.and_return { |*arg| @arg = arg } # store the args
      @game.add_observer mock, :vote_required
      @game.state.thread.join
      @game.vote_complete true
    end
    @arg.should_equal ['dane', 'two', 'rejected by aspell, proper noun?']
  end
    
  specify "should add 'daen' to player one's word list after :vote_complete callback with true" do
    @game.state.thread.join
    @game.vote_complete true
    @game.words['one'].should_include 'daen'
  end
    
  specify "should not add 'daen' to player one's word list after :vote_complete callback with false" do
    @game.state.thread.join
    @game.vote_complete false
    @game.words['one'].should_not_include 'daen'
  end
    
  specify "should trigger :vote_required callback for 'dane' after adding sufficient votes for 'daen'" do
    FlexMock.use('mock') do |mock|
      mock.should_receive(:vote_required).twice.and_return { |*arg| @arg = arg } # store the args
      @game.add_observer mock, :vote_required
      @game.state.thread.join
      @game.add_vote('one', true)
      @game.add_vote('two', true)
    end
    @arg.should_equal ['dane', 'two', 'rejected by aspell, proper noun?']
  end
    
  specify "should trigger :times_up, :verified, :vote_required (twice), " + 
    "and :game_over callbacks during the course of a game" do
    FlexMock.use('mock') do |mock|
      mock.should_receive(:times_up).once
      mock.should_receive(:verified).once
      mock.should_receive(:vote_required).twice
      mock.should_receive(:game_over).once.and_return { |*args| @args = args }
      @game.add_observer mock, :all
      @game.state.thread.join
      @game.add_vote('one', true) # daen
      @game.add_vote('two', true) # daen
      @game.add_vote('one', false) # dane
      @game.add_vote('two', false) # dane
    end
    #{ 'one' => ['deaden', 'dread', 'snap', 'daen'], 'two' => ['case', 'cased', 'snap', 'dane'] }
    @args.first.should_equal [
      ["one", 7, ["daen", "deaden", "dread", "read"], 5], 
      ["two", 3, ["case", "cased"], 4] 
    ]
  end
  
end
