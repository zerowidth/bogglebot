require 'game' # boggle game
require 'irc/plugin'

require 'enumerator' # each_slice

# include Boggle

class BoggleBot < IRC::Plugin

  DEFAULT_CONFIG = {
    :game_channel => :required,#'#boggle',
    :start_wait => 5,
    :game_length => 180,
    :game_timeout => 600,
    :warning_timeouts => [
      [60, '2 minutes left!'],
      [120, '1 minute left!'],
      [150, '30 seconds!'],
      [170, '10 seconds!']
    ]
  }.freeze
  
  def initialize(client)
    super(client)
    DEFAULT_CONFIG.each do |opt, val|
      @client.merge_config opt => val unless @client.config[opt]
    end
    @game = Boggle::Game.new
    @game.add_observer self, :all
    
    @game_channel = @client.config[:game_channel]
  end
  
  # ----- IRC::Client callbacks -----
  
  def registered_with_server
    @client.send_raw("JOIN #{@game_channel}")
    if @client.config[:operuser] && @client.config[:operpass]
      @client.send_raw("OPER #{@client.config[:operuser]} #{@client.config[:operpass]}")
      @client.send_raw("MODE #{@client.state[:newnick].first} +F")
    end
  end
  
  def channel_message(chan, message, who)
    message = message.downcase.strip
    case message
    when /^!help/
      help(who.nick)
    when /^!start(\s.*)?/
      if @game.running?
        @client.channel_message(@game_channel, "Game already in progress")
        return
      end
      if @starting
        @client.channel_message(@game_channel, "Game is starting, hang on")
        return
      end
      
      start_wait = @client.config[:start_wait]
      
      @starting = true # prevent multiple !start's in the start_wait window
      @client.channel_message(@game_channel, "\002Starting new game in #{start_wait} seconds!\002")
      
      # wait for a bit before starting the game
      sleep(start_wait)
      
      # start the game
      @game.start :game_length => @client.config[:game_length]
      @starting = false
      @vote_header = false
      logger.info "board id #{@game.board_id}" if logger
      display_board
      
      # start additional timers
      @warning_threads = []
      # doing |time, message| somehow overwrote message. w. t. f. TODO WHAT
      @client.config[:warning_timeouts].each do |info| 
        @warning_threads << Thread.new do
          sleep(info[0])
          @client.channel_message(@game_channel, info[1])
        end
      end
      
      @timeout_thread = Thread.new do
        sleep(@client.config[:game_timeout])
        @client.channel_message(@game_channel, "\002\0034Ur E Ur E Voting took too long. Canceling game!")
        @game.cancel
        @warning_threads.each { |t| t.kill }
      end
      
    when /^(v|vote)\s+(\S+)\s+(y|yes|n|no)/
      skip, word, vote = $1, $2, $3
      @game.add_vote(who.nick, vote == 'y' || vote =='yes' ) if @vote_word == word
    end
  end
  
  def private_message(me, message, who)
    message = message.downcase.strip
    case message
    when /^!help/
      help(who.nick)
    when 'b'
      display_board(who.nick) # private
    else
      if @game.running?
        words = message.split
        words.each do |word|
          response = @game.add_word(who.nick, word)
          @client.private_message(who.nick, "#{word}: #{response}") if response
        end
      end
    end
    
  end
  
  # ----- Boggle::Game callbacks -----
  def times_up
    @client.channel_message('#boggle', "\002\0034Time's Up!")
  end
  
  def verified(info)
    # print out summary of the game
    word_summary(info)    
    
    # print out the duplicates
    return if info[:duplicates].empty?
    info[:duplicates].each_slice(3) do |slice|
      msg = []
      slice.each do |word, players|
        trunc = players.map {|p| p[0..3]}
        msg << "\002#{word}\002 (#{trunc.join(', ')})"
      end
      @client.channel_message(@game_channel, msg.join(', '))
    end
  end

  def vote_required(word, player, reason)
    unless @vote_header
      @client.channel_message(@game_channel, "\0039voting time!\003 to vote for a word, type 'v<ote> <word> <y|yes|n|no>." + 
      " >50% vote required!")
      @vote_header = true
    end
    @vote_word = word
    @client.channel_message(@game_channel, "\0039vote!\003 #{player}: \002#{word}\002 (#{reason})")
  end
  
  def game_over(final_score)
    # [player, score, words, found_word_count ]
    @vote_word = nil
    @timeout_thread.kill
    
    @warning_threads.each { |t| t.kill } if @warning_threads
    
    @client.channel_message(@game_channel, "\002GAME OVER\002")
    
    final_score.each do |score_info|
      player, score, words, words_found = score_info
      
      word_strs = []
      if words.empty?
        word_strs << "\002no words\002"
      else
        words.each_slice(30) { |slice| word_strs << "\002" + slice.join("\002, \002") + "\002" }
      end
      
      word_strs[0] = "#{player}: #{score} (#{word_strs[0]}"
      if word_strs.size > 1 
        last = word_strs.last
        word_strs = word_strs[0..-2].map { |str| str += ',' } 
        word_strs << last
      end
      word_strs[-1] += ") (#{words.size}/#{words_found})"

      word_strs.each { |str| @client.channel_message(@game_channel, str) }
    end
    
    return unless final_score.size > 0

    winners = final_score.find_all {|score| score[1] == final_score.first[1] }
    if winners.size == 1
      @client.channel_message(@game_channel, "\002\0038WINNER: #{winners.first[0]}") 
    else
      @client.channel_message(@game_channel, "\002\0038TIE: #{winners.map {|winner| winner[0]}.join(', ')}") 
    end
    
  end
  
  private # -----
  
  def help(who)
    @client.private_message who, "given a 5x5 grid of letters, find all the words of length 4 or more. " +
      "letters must be contiguous in any direction, including diagonal."
    @client.private_message who, "you may not use a character for a word more than once. " + 
      "proper nouns are not allowed, conjunctions and plurals are."
    @client.private_message who, "scoring: 4 characters: 1 pt, 5 chars 2pts, 6 chars 3pts, 7 chars 5pts, 8+ chars 11pts"
    @client.private_message who, "words found by more than one player don't count, " + 
      "and all other words are checked against aspell for validity"
    @client.private_message who, "any words that aspell doesn't like may be voted on by all players."
  end
  
  def display_board(who = nil)
    @game.board.each_slice(5) do |row|
      out = "\002" + row.map {|cube| cube.ljust(2).capitalize}.join('') + "\002"
      if who
        @client.private_message(who, out)
      else
        @client.channel_message(@game_channel, out)
      end
    end if @game.board
  end
  
  def word_summary(info)
    # info is hash of :total (count), :rejected (count), and :duplicates (hash)
    if info[:total] == 0
      @client.channel_message(@game_channel, "No words were found!")
      return
    elsif info[:total] == 1
      str = "Out of 1 word found, "
    else
      str = "Out of #{info[:total]} words found, "
    end
    
    if info[:rejected] == 0
      str += "none were rejected "
    elsif info[:rejected] == 1
      str += "1 was rejected "
    else
       str += "#{info[:rejected]} were rejected "
    end
    
    if info[:duplicates].size == 0
      str += "and no duplicates were removed"
    elsif info[:duplicates].size == 1
      str += "and 1 duplicate was removed:"
    else
      str += "and #{info[:duplicates].size} duplicates were removed:"
    end
    
    @client.channel_message(@game_channel, str)
    
  end
  
end
