require 'bogglebot'
require 'irc/message'

require 'rubygems'
require 'flexmock'
require 'active_support/core_ext/kernel/reporting' # for silence_warnings

# ----- fixtures -----
def message(key)
  one = IRC::MessageInfo::User.new('one', '~user@server.com')
  two = IRC::MessageInfo::User.new('two', '~user@server.com')
  messages = {
    :start => [ '#boggle', '!start', one],
    :priv_word => [ 'bogglebot', 'dread', one ],
    :priv_words => [ 'bogglebot', 'dread snap dead', one],
    :chan_word => [ '#boggle', 'dread', one ],
    :public_help => [ '#boggle', '!help', one],
    :private_help => [ 'bogglebot', '!help', one],
    :draw_board_request => [ 'bogglebot', 'b', one],
    :draw_board_request_whitespace => [ 'bogglebot', '    b', one],
    :yes_vote_1 => [ '#boggle', 'vote word yes', one],
    :yes_vote_2 => [ '#boggle', 'vote word y', one],
    :yes_vote_3 => [ '#boggle', 'v word yes', one],
    :yes_vote_4 => [ '#boggle', 'v word y', one],
    :no_vote_1 => [ '#boggle', 'vote word no', one],
    :no_vote_2 => [ '#boggle', 'vote word n', one],
    :no_vote_3 => [ '#boggle', 'v word no', one],
    :no_vote_4 => [ '#boggle', 'v word n', one],
    :other_vote => [ '#boggle', 'v other y', one],
    :vote_with_trailing_word => [ '#boggle', 'v word n stuff', one],
  }
  messages[key]
end

# ----- setup -----
module Notification
  attr_reader :observers
end
class BoggleBot
  attr_accessor :game, :vote_word
  
  # silence_warnings do
  #   GAME_START_WAIT = 0.1
  #   GAME_LENGTH = 0.2
  #   GAME_TIMEOUT = 0.25
  #   WARNING_TIMEOUTS = [] # set to more only during one specification
  # end
  
end

SPEC_CONFIG = {
  :game_channel => '#boggle',
  :start_wait => 0.1,
  :game_length => 0.2,
  :game_timeout => 0.25,
  :warning_timeouts => [].freeze, # set to more than one during one specification only
  :operuser => 'operuser', :operpass => 'operpass'
}

# ----- specifications -----

context "A new BoggleBot instance" do
  setup do
    @client = FlexMock.new('client')
    @client.should_receive(:config).and_return(SPEC_CONFIG)
    @bot = BoggleBot.new(@client)
  end
  teardown do
    @client.mock_verify
  end
  
  specify "should have a game" do
    @bot.game.should_not_be_nil
  end
    
  specify "should be an observer for all callbacks on the game" do
    @bot.game.observers[:all].should_include @bot
  end
    
  specify "should respond to registered_with_server by joining \#boggle, sending oper pass, and setting floodmode" do
    @client.should_receive(:config).and_return()
    @client.should_receive(:state).and_return({:nick => nil, :newnick => ['BoggleBot']})
    @args = []
    @client.should_receive(:send_raw).with(String).and_return { |arg| @args << arg }
    @bot.registered_with_server
    @args.should_equal [
      'JOIN #boggle',
      "OPER operuser operpass", 
      "MODE BoggleBot +F"
    ]
  end
  
  specify "should start a new game and display the board after :start_wait seconds " + 
    "when public message !start is received" do
    @args = []
    @client.should_receive(:channel_message).and_return { |*args| @args << args[1] }
    t = Thread.new { @bot.channel_message *message(:start) }
    t.join(0.05)
    t.should_be_alive
    @bot.game.should_not_be_running
    t.join
    @bot.game.should_be_running
    @args.size.should_equal 6
    @args.first.should_equal "\002Starting new game in #{SPEC_CONFIG[:start_wait]} seconds!\002"
    @args[1..5].each do |message|
      message.should_satisfy do |msg|
        msg =~ /\002(\w\w|\w\s){5}\002/
      end
    end
  end
  
  specify "should ignore second !start (with error message) while waiting for first one" do
    @client.should_receive(:channel_message).with(String, String).times(2)
    t = Thread.new { @bot.channel_message *message(:start) }
    t.join(0.05)
    t.should_be_alive
    second = Thread.new { @bot.channel_message *message(:start) }
    second.join(0.15)
    second.should_not_be_alive
  end
  
  specify "should set up warning timers to send timeout warnings as game timer progresses" do
    @args = []
    @client.should_receive(:channel_message).and_return { |*args| @args << args[1] if args[1] =~ /warning/ }
    # @client.should_receive(:channel_message).with(String, /(?:\002.*|warning timeout \d)/).times(9)
    # silence_warnings do
      SPEC_CONFIG[:warning_timeouts] = [
          [0.01, 'warning timeout 1'],
          [0.02, 'warning timeout 2'],
          [0.03, 'warning timeout 3']
        ]
    # end
    @bot.channel_message *message(:start) # waits longer than the timers, so timers should trigger
    sleep(0.1)
    @args.should_equal [
      'warning timeout 1',
      'warning timeout 2',
      'warning timeout 3'
    ]
  end

end

context "A BoggleBot with a started game" do
  setup do
    # client mock, records calls to channel message
    @client = FlexMock.new('mock client')
    @args = []
    @client.should_receive(:channel_message).and_return { |*args| @args << args[1] }
    @client.should_receive(:config).and_return(SPEC_CONFIG)
    
    # mock game
    @game = FlexMock.new('mock game')
    @game.should_receive(:running?).and_return(true)
    
    # start up bot, clear out "real" game, and replace it with the mock
    # (doing it this way so timers get started)
    @bot = BoggleBot.new(@client)
    @bot.channel_message *message(:start)
    @bot.game.observers[:all].clear # cancel any callbacks in the "real" game
    @bot.game = @game
    
    @args = [] # ignore whatever just got added by the start command
  end
  teardown do
    @client.mock_verify
    @game.mock_verify
  end
  
  specify "should print the board when asked in private" do
    board = (97..121).to_a.inject([]) { |acc, num| acc << num.chr }
    @game.should_receive(:board).and_return(board)
    @client.should_receive(:private_message).with('one', /\002(\w\w|\w\s){5}\002/).times(5)
    @bot.private_message *message(:draw_board_request)
  end
  
  specify "should print board in private when asked even with leading whitespace" do
    board = (97..121).to_a.inject([]) { |acc, num| acc << num.chr }
    @game.should_receive(:board).and_return(board)
    @client.should_receive(:private_message).with('one', /\002(\w\w|\w\s){5}\002/).times(5)
    @bot.private_message *message(:draw_board_request_whitespace)
  end
  
  specify "should accept single player word in privmsg" do
    @game.should_receive(:add_word).with('one', 'dread').and_return(nil).once
    @bot.private_message *message(:priv_word)
  end
  
  specify "should accept player words in privmsg" do
    @game.should_receive(:add_word).times(3)
    @bot.private_message *message(:priv_words)
  end
  
  specify "should print error in privmsg when applicable (word not on board, etc.)" do
    @game.should_receive(:add_word).with('one', 'dread').and_return('error').once
    @client.should_receive(:private_message).with('one', 'dread: error')
    @bot.private_message *message(:priv_word)
  end
  
  specify "should print help message in private when channel messaged !help" do
    @client.should_receive(:private_message).with('one', FlexMock.any).times(5)
    @bot.channel_message *message(:public_help)
  end
  
  specify "should print help message when private messaged !help" do
    @client.should_receive(:private_message).with('one', FlexMock.any).times(5)
    @bot.private_message *message(:private_help)
  end
  
  specify "should register vote for current vote word with yes vote input" do
    @bot.vote_word = 'word'
    @game.should_receive(:add_vote).with('one', true).times(4)
    @bot.channel_message *message(:yes_vote_1)
    @bot.channel_message *message(:yes_vote_2)
    @bot.channel_message *message(:yes_vote_3)
    @bot.channel_message *message(:yes_vote_4)
  end
  
  specify "should register no vote for current vote word with no vote input" do
    @bot.vote_word = 'word'
    @game.should_receive(:add_vote).with('one', false).times(4)
    @bot.channel_message *message(:no_vote_1)
    @bot.channel_message *message(:no_vote_2)
    @bot.channel_message *message(:no_vote_3)
    @bot.channel_message *message(:no_vote_4)
  end
  
  specify "should handle vote even with trailing word/whitespace" do
    @bot.vote_word = 'word'
    @game.should_receive(:add_vote).with('one', false).times(1)
    @bot.channel_message *message(:vote_with_trailing_word)
  end
  
  specify "should ignore vote when not voting or vote word is different" do
    @bot.vote_word = 'word'
    @game.should_receive(:add_vote).never
    @bot.channel_message *message(:other_vote)
  end
  
  specify "should say 'time's up' when :times_up callback occurs" do
    @client.should_receive(:channel_message).with('#boggle', "\002\0034Time's Up!").once
    @bot.times_up
  end
  
  specify "should list out totals words and duplicate words with the :verified callback, with truncated nicks" do
  	@bot.verified :total => 4, :rejected => 2, 
  	  :duplicates => { 'snap'=> %w{one two}, 'someword' => %w{long_nick, other_long_nick}  }
    @args.should_equal [ 'Out of 4 words found, 2 were rejected and 2 duplicates were removed',
      'The following words were found by multiple players:', 
      "\002someword\002 (long, othe), \002snap\002 (one, two)"
    ]
  end
  
  specify "should include proper pluralization for summary -- 1 was, 2 were, etc." do
    @bot.verified :total => 2, :rejected => 1, :duplicates => {'foo'=>%w{bar baz}}
    @args.first.should_equal 'Out of 2 words found, 1 was rejected and 1 duplicate was removed'
  end
  
  specify "should also properly pluralize if 0 rejected or duplicate words were found" do
    @bot.verified :total => 1, :rejected => 0, :duplicates => {}
    @args.first.should_equal 'Out of 1 word found, none were rejected and no duplicates were removed'
  end
  
  specify "should say so if no words were found at all" do
    @bot.verified :total => 0, :rejected => 0, :duplicates => {}
    @args.first.should_equal 'No words were found!'
  end
  
  specify "should not list out duplicates if no duplicates were found" do
    # @client.should_receive(:channel_message).never # doesn't work, overruled by previous arg
    @bot.verified :total => 0, :duplicates => {}, :rejected => 0
    @args.size.should_equal 1 # only one channel message should be sent, the summary
  end
  
  specify "should print out 'voting' header for first vote, as well as the vote (:vote_required callback)" do
  	@bot.vote_required('word', 'player', 'rejected by aspell')
  	@bot.vote_required('second', 'player', 'rejected by aspell, proper noun?')
    @args.should_equal [ "\0039voting time!\003 to vote for a word, type 'v<ote> <word> <y|yes|n|no>." + 
      " >50% vote required!", 
      "\0039vote!\003 player: \002word\002 (rejected by aspell)",
      "\0039vote!\003 player: \002second\002 (rejected by aspell, proper noun?)"
    ]
  end
  
  specify "should print out 'game over' and final scores with the :game_over callback" do
    @bot.game_over [["one", 6, ["daen", "deaden", "dread"], 4], 
      ["two", 3, ["case", "cased"], 4],
      ["three", 0, [], 1]]
    @args.should_equal [ "\002GAME OVER\002", 
      "one: 6 (\002daen\002, \002deaden\002, \002dread\002) (3/4)",
      "two: 3 (\002case\002, \002cased\002) (2/4)",
      "three: 0 (\002no words\002) (0/1)",
      "\002\0038WINNER: one"
    ]
  end
  
  specify "should print out 'game over' without scores if no words were entered" do
    @bot.game_over []
    @args.should_equal [ "\002GAME OVER\002" ]
  end
  
  specify "should print out 'game over' with tie if there's a tie" do
    @bot.game_over [['one', 1, ['word'], 1], ['two', 1, ['word'], 1]]
    @args.first.should_equal "\002GAME OVER\002"
    @args.last.should_equal "\002\0038TIE: one, two"
  end
  
  specify "should cancel game if stuck in vote past specified time limit" do
    @game.should_receive(:cancel).once
    @bot.vote_required('word', 'player', 'rejected by aspell') # stuck waiting for vote
    sleep(0.3)
    @args.should_include "\002\0034Ur E Ur E Voting took too long. Canceling game!"
  end
  
  specify "should not cancel game if not stuck in vote past specified time limit" do
    @client.should_receive(:cancel).never
    @bot.vote_required('word', 'player', 'rejected by aspell') # bot needs a vote
    @bot.game_over([]) # bot game over, game state should be nil again
    @args.should_not_include "\002\0034Ur E Ur E Voting took too long. Canceling game!"
  end
  
end