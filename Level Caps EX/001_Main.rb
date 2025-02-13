class Pokemon
  def level=(value)
    validate value => Integer
    max_lvl = GameData::GrowthRate.max_level
    if value < 1 || value > max_lvl
      limit = (value < 1) ? ["below the minimum of level 1", "1"] : ["above the maximum of level #{max_lvl}", max_lvl.to_s]
      echoln _INTL("Level {1} for {2} is not valid as it goes {3}. Reset to {4}", value, self, limit[0], limit[1])
      value = value.clamp(1, max_lvl)
    end
    @exp = growth_rate.minimum_exp_for_level(value)
    @level = value
  end

  def crosses_level_cap?(is_player)
    return false unless LevelCapsEX.applicable_level_cap?(is_player)
    LevelCapsEX.soft_cap? && self.level >= LevelCapsEX.level_cap
  end

  def level
    @level ||= growth_rate.level_from_exp(@exp)
    self.level = GameData::GrowthRate.max_level if @level > GameData::GrowthRate.max_level
    @level
  end

  def apply_exp(exp, is_player)
    max_exp = growth_rate.minimum_exp_for_level(LevelCapsEX.level_cap)
    exp = [exp, max_exp - @exp].min if crosses_level_cap?(is_player)
    self.exp += exp
  end
end

module GameData
  class GrowthRate
    def self.max_level
      LevelCapsEX.hard_level_cap
    end
  end
end

class Battle
  def pbGainExpOne(idxParty, defeatedBattler, numPartic, expShare, expAll, showMessages = true)
    pkmn = pbParty(0)[idxParty]
    growth_rate = pkmn.growth_rate
    return if pkmn.exp >= growth_rate.maximum_exp

    isPartic = defeatedBattler.participants.include?(idxParty)
    hasExpShare = expShare.include?(idxParty)
    level = defeatedBattler.level
    exp = calculate_exp(isPartic, hasExpShare, level, defeatedBattler, numPartic, expShare, expAll)
    return if exp <= 0

    exp = apply_exp_modifiers(exp, pkmn, defeatedBattler)
    pkmn.apply_exp(exp, true)

    show_exp_message(showMessages, pkmn, exp)
    handle_level_up(pkmn, exp, idxParty)
  end

  private

  def calculate_exp(isPartic, hasExpShare, level, defeatedBattler, numPartic, expShare, expAll)
    a = level * defeatedBattler.pokemon.base_exp
    exp = 0
    if expShare.length > 0 && (isPartic || hasExpShare)
      exp = if numPartic == 0
              a / (Settings::SPLIT_EXP_BETWEEN_GAINERS ? expShare.length : 1)
            elsif Settings::SPLIT_EXP_BETWEEN_GAINERS
              (isPartic ? a / (2 * numPartic) : 0) + (hasExpShare ? a / (2 * expShare.length) : 0)
            else
              isPartic ? a : a / 2
            end
    elsif isPartic
      exp = a / (Settings::SPLIT_EXP_BETWEEN_GAINERS ? numPartic : 1)
    elsif expAll
      exp = a / 2
    end
    exp
  end

  def apply_exp_modifiers(exp, pkmn, defeatedBattler)
    exp = (exp * 1.5).floor if Settings::MORE_EXP_FROM_TRAINER_POKEMON && trainerBattle?
    exp = scaled_exp(exp, defeatedBattler, pkmn) if Settings::SCALED_EXP_FORMULA
    exp = foreign_pokemon_exp(exp, pkmn)
    exp = exp * 3 / 2 if $bag.has?(:EXPCHARM)
    exp = Battle::ItemEffects.triggerExpGainModifier(pkmn.item, pkmn, exp) if Battle::ItemEffects.triggerExpGainModifier(pkmn.item, pkmn, exp) >= 0
    exp = affection_level_exp(exp, pkmn) if Settings::AFFECTION_EFFECTS && @internalBattle && pkmn.affection_level >= 4 && !pkmn.mega?
    exp
  end

  def scaled_exp(exp, defeatedBattler, pkmn)
    exp /= 5
    levelAdjust = ((2 * defeatedBattler.level) + 10.0) / (pkmn.level + defeatedBattler.level + 10.0)
    levelAdjust **= 5
    levelAdjust = Math.sqrt(levelAdjust)
    (exp * levelAdjust).floor + 1
  end

  def foreign_pokemon_exp(exp, pkmn)
    if (pkmn.owner.id != pbPlayer.id || (pkmn.owner.language != 0 && pkmn.owner.language != pbPlayer.language))
      exp = (exp * 1.7).floor if pkmn.owner.language != 0 && pkmn.owner.language != pbPlayer.language
      exp = (exp * 1.5).floor
    end
    exp
  end

  def affection_level_exp(exp, pkmn)
    exp * 6 / 5
  end

  def show_exp_message(showMessages, pkmn, expGained)
    if showMessages
      message = _INTL("{1} got {2} Exp. Points!")
      message = _INTL("{1} got a boosted {2} Exp. Points!") if isOutsider
      message = _INTL("{1} got a reduced {2} Exp. Points!") if over_level_cap
      pbDisplayPaused(_INTL(message, pkmn.name, expGained))
    end
  end

  def handle_level_up(pkmn, expGained, idxParty)
    curLevel = pkmn.level
    newLevel = pkmn.growth_rate.level_from_exp(pkmn.exp)
    raise_invalid_level_exception(pkmn, curLevel, newLevel, pkmn.exp, expGained) if newLevel < curLevel

    $stats.total_exp_gained += expGained
    tempExp1 = pkmn.exp
    battler = pbFindBattler(idxParty)
    level_up_loop(pkmn, tempExp1, pkmn.exp, curLevel, newLevel, battler)
  end

  def raise_invalid_level_exception(pkmn, curLevel, newLevel, expFinal, expGained)
    debugInfo = "Levels: #{curLevel}->#{newLevel} | Exp: #{pkmn.exp}->#{expFinal} | gain: #{expGained}"
    raise _INTL("{1}'s new level is less than its current level, which shouldn't happen.", pkmn.name) + "\n[#{debugInfo}]"
  end

  def level_up_loop(pkmn, tempExp1, expFinal, curLevel, newLevel, battler)
    loop do
      levelMinExp = pkmn.growth_rate.minimum_exp_for_level(curLevel)
      levelMaxExp = pkmn.growth_rate.minimum_exp_for_level(curLevel + 1)
      tempExp2 = [levelMaxExp, expFinal].min
      pkmn.exp = tempExp2
      @scene.pbEXPBar(battler, levelMinExp, levelMaxExp, tempExp1, tempExp2)
      tempExp1 = tempExp2
      curLevel += 1
      break if curLevel > newLevel
      pbCommonAnimation("LevelUp", battler) if battler
      old_stats = [pkmn.totalhp, pkmn.attack, pkmn.defense, pkmn.spatk, pkmn.spdef, pkmn.speed]
      pkmn.changeHappiness("levelup")
      pkmn.calc_stats
      battler&.pbUpdate(false)
      @scene.pbRefreshOne(battler.index) if battler
      pbDisplayPaused(_INTL("{1} grew to Lv. {2}!", pkmn.name, curLevel)) { pbSEPlay("Pkmn level up") }
      @scene.pbLevelUp(pkmn, battler, *old_stats)
      learn_moves(pkmn, curLevel, idxParty)
    end
  end

  def learn_moves(pkmn, curLevel, idxParty)
    pkmn.getMoveList.each { |m| pbLearnMove(idxParty, m[1]) if m[0] == curLevel }
  end
end

class Battle::Battler
  alias __level_cap__pbObedienceCheck? pbObedienceCheck? unless method_defined?(:__level_cap__pbObedienceCheck?)

  def pbObedienceCheck?(*args)
    ret = __level_cap__pbObedienceCheck?(*args)
    db = @disobeyed
    @disobeyed = false
    return ret if ret || db
    return true if LevelCapsEX.level_cap_mode != 3
    level_check(args[0])
  end

  def level_check(action)
    lv_diff = @level - LevelCapsEX.level_cap
    lv_diff = 5 if lv_diff >= 5
    disobedient = rand(5 - lv_diff) == 0
    return pbDisobey(action, (lv_diff * 2)) if lv_diff >= 5 || disobedient
    true
  end

  alias __level_cap__pbDisobey pbDisobey unless method_defined?(:__level_cap__pbDisobey)

  def pbDisobey(*args)
    ret = __level_cap__pbDisobey(*args)
    @disobeyed = true
    ret
  end
end