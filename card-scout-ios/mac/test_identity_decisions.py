import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

from identity_decisions import IdentityResolver, serials, ocr_agrees, ocr_fields
from card_lookup import CardLookup
from test_card_lookup import detection, CARD, SET, PARALLEL

OTHER = '44444444-4444-4444-a444-444444444444'
RELEASE = '55555555-5555-4555-a555-555555555555'


def card(name='Tyrone Tracy Jr.', identifier=CARD):
    c = detection()['card']; c.update(id=identifier, name=name, releaseId=RELEASE)
    return c


class IdentityResolverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.root=Path(self.temp.name)
        self.job=self.root/'job';self.job.mkdir();(self.job/'front.jpg').write_bytes(b'\xff\xd8\xfftest')
        self.choices=[]; self.calls=[]
        def transport(payload):
            self.calls.append(payload)
            choice=self.choices.pop(0); q=payload['questions'][0]
            return dict(status='completed',answers=[dict(type='choice',name=q['name'],choice=choice,
                probabilities=[dict(value=c['value'],probability=int(c['value']==choice)) for c in q['choices']])])
        self.resolver=IdentityResolver(self.root, transport)
        self.client=Mock(); self.client.request.return_value=dict(card(), parallels=[dict(id=PARALLEL,name='Yellow Wave Refractor',numberedTo=275)],parallelCount=1)

    def tearDown(self): self.temp.cleanup()
    def hints(self,text): (self.job/'capture-text.txt').write_text(text)
    def resolve(self,c,confidence='High'):return self.resolver.resolve(dict(card=c,confidence=confidence,zIndex=0),self.job,self.client)

    def test_high_card_and_high_parallel_with_agreeing_ocr_need_no_calls(self):
        self.hints('Tyrone Tracy Jr. #147 201/275')
        c=card();c['parallelSuggestions']=[dict(id=PARALLEL,name='Yellow Wave',confidence='High',numberedTo=275)]
        result=self.resolve(c)
        self.assertEqual(result['card']['id'],CARD);self.assertEqual(result['observedSerial'],'201/275')
        self.assertEqual(self.calls,[]);self.client.request.assert_not_called()

    def test_low_wrong_top_corrects_player_then_parallel_without_manual_input(self):
        c=card('Fred Warner',OTHER);c['suggestions']=[dict(card(), parallelSuggestions=[dict(id=PARALLEL,confidence='Medium')])]
        c['parallelSuggestions']=[dict(id=OTHER,name='Gold',confidence='High',numberedTo=50)]
        self.hints('TYRONE TRACY JR. 201/275');self.choices=[CARD,PARALLEL]
        result=self.resolve(c,'Low')
        self.assertEqual(result['card']['id'],CARD)
        self.assertEqual(result['card']['parallelSuggestions'][0]['id'],PARALLEL)
        self.assertEqual([p['questions'][0]['name'] for p in self.calls],['card','parallel'])
        self.assertNotIn(OTHER,[c['value'] for c in self.calls[1]['questions'][0]['choices']])

    def test_medium_and_high_contradiction_escalate(self):
        for confidence in ['Medium','High']:
            c=card('Fred Warner',OTHER);c['suggestions']=[card()]
            self.hints('Tyrone Tracy Jr. #147 201/275');self.choices=[CARD]
            result = self.resolve(c,confidence)
            self.assertEqual(result['card']['id'], CARD)
            self.assertTrue(result['variantUnresolved'])
        self.assertEqual(len(self.calls),2)

    def test_missing_ocr_escalates_and_ambiguous_identity_stops_before_catalog(self):
        self.choices=['unclear'];self.assertEqual(self.resolve(card()),{})
        self.client.request.assert_not_called()

    def test_high_card_does_not_confirm_medium_parallel(self):
        self.hints('Tyrone Tracy Jr. #147');c=card()
        c['parallelSuggestions']=[dict(id=PARALLEL,name='Yellow Wave',confidence='Medium')]
        self.choices=['unclear'];result=self.resolve(c)
        self.assertEqual([p['questions'][0]['name'] for p in self.calls], ['parallel'])
        self.assertTrue(result['variantUnresolved'])
        lookup=CardLookup(self.root,self.client,resolver=self.resolver)
        try:
            a=lookup.result(result,[],self.job)['analysis']
            self.assertFalse(a['identityConfirmed']);self.assertIsNotNone(a['cardSightIdentity'])
            self.assertEqual(a['insights']['marketReferences'],[])
        finally:lookup.executor.shutdown()

    def test_serial_conflict_vetoes_high_suggestion_and_model_choice(self):
        self.hints('Tyrone Tracy Jr. #147 201/50');c=card()
        c['parallelSuggestions']=[dict(id=PARALLEL,name='Yellow Wave',confidence='High',numberedTo=275)]
        self.choices=[]
        self.assertTrue(self.resolve(c)['variantUnresolved'])

    def test_invented_uuid_failure_and_incomplete_catalog_fail_closed(self):
        self.choices=[OTHER];self.assertEqual(self.resolve(card(),'Low'),{})
        self.hints('Tyrone Tracy Jr. #147');self.client.request.return_value=dict(parallels=[],total_count=401)
        self.assertTrue(self.resolve(card())['variantUnresolved'])

    def test_resolved_detection_reused_but_changed_ocr_rechecks(self):
        self.client.request.return_value=dict(success=True,detections=[dict(card=card(),confidence='Low')])
        resolver=Mock();resolver.resolve.return_value=dict(card=card(),confidence='High')
        lookup=CardLookup(self.root,self.client,resolver=resolver)
        try:
            lookup.identify(self.job,[]);lookup.identify(self.job,[])
            self.assertEqual(resolver.resolve.call_count,1)
            self.hints('changed');lookup.identify(self.job,[])
            self.assertEqual(resolver.resolve.call_count,2)
            self.assertEqual(self.client.request.call_count,1)
        finally:lookup.executor.shutdown()

    def test_corrected_card_never_inherits_wrong_high_suggestion(self):
        self.choices = [CARD]
        top = dict(card('Wrong Player', OTHER), suggestions=[card()],
                   parallelSuggestions=[dict(id=PARALLEL, name="Gold", confidence="High")])
        result = self.resolve(top, 'Low')
        self.assertEqual(result['card']['id'], CARD)
        self.assertEqual(result['card']['parallelSuggestions'], [])
        self.assertEqual([p['questions'][0]['name'] for p in self.calls], ['card'])
        self.assertEqual(json.loads((self.job/'identity-resolution.json').read_text())['parallel'], 'base_default_after_card_correction')

    def test_model_cannot_override_ocr_player_conflict(self):
        c=card('Fred Warner',OTHER);c['suggestions']=[card()]
        self.hints('Tyrone Tracy Jr. #147');self.choices=[OTHER]
        self.assertEqual(self.resolve(c,'High'),{})

    def test_parallel_metadata_is_reused_and_impossible_copy_number_is_not_saved(self):
        self.assertEqual(serials('1120//275'),{('unknown','275')})
        self.assertEqual(serials('201/275'),{('201','275')})
        self.resolver.parallels(self.client,card());self.resolver.parallels(self.client,card())
        self.assertEqual(self.client.request.call_count,1)

    def test_no_suggestion_defaults_to_eligible_base_without_decisions(self):
        self.hints("Tyrone Tracy Jr. #147")
        for c in (card(), dict(card(), parallelSuggestions=[]), dict(card(), parallelSuggestions=None)):
            result = self.resolve(c)
            self.assertTrue(result["card"]["ordinaryBaseCatalog"])
            self.assertEqual(result["card"]["parallelSuggestions"], [])
            self.assertIn("base", {p["id"] for p in result["eligibleParallels"]})
            self.assertEqual(json.loads((self.job/"identity-resolution.json").read_text())["parallel"], "cardsight_base_default")
        c = dict(card(), attributes=["SSP"], ordinaryBaseCatalog=True)
        self.assertFalse(self.resolve(c)["card"].get("ordinaryBaseCatalog"))
        self.assertEqual(self.calls, [])
        self.client.request.assert_called_once()

    def test_collection_zero_excludes_special_catalog_metadata(self):
        from identity_decisions import ordinary_base_metadata
        for flag in [dict(variationOf=OTHER), dict(variations=[OTHER]), dict(isParallelOnly=True),
                     dict(numberedTo=99), dict(attributes=["Autograph"]), dict(description="Image variation"),
                     dict(setName="Prospects"), dict(setName="Topps Profiles"), dict(fields=[dict(key="Rarity", value="SP")])]:
            with self.subTest(flag=flag):
                self.assertFalse(ordinary_base_metadata(dict(card(), **flag)))
        self.assertTrue(ordinary_base_metadata(dict(card(), attributes=["RC","NFL-DET"])))
        self.assertTrue(ordinary_base_metadata(dict(card(), year="2026", releaseName="Bowman", setName="Chrome")))

    def test_weak_winning_choice_is_unresolved(self):
        def transport(payload):
            q=payload['questions'][0]
            return dict(answers=[dict(type='choice',name=q['name'],choice=CARD,
                probabilities=[dict(value=CARD,probability=.51),dict(value='unclear',probability=.49)])])
        self.resolver.transport=transport
        self.assertEqual(self.resolve(card(),'Low'),{})

    def test_ocr_ignores_career_years_and_print_codes_but_keeps_real_conflicts(self):
        c=card()
        text='Tyrone Tracy Jr.\nDrafted 2024; played 2023 and 2022. Born 2002.\nCMP#142284\n© 2025 THE TOPPS COMPANY'
        self.assertTrue(ocr_agrees(c,[c],text))
        self.assertEqual(ocr_fields(text)['numbers'],set())
        self.assertEqual(ocr_fields('Rückseite: BCV-187')['queries'],{'BCV-187'})
        self.assertFalse(ocr_agrees(c,[c],text+'\nCard number: 148'))
        self.assertFalse(ocr_agrees(c,[c],'Tyrone Tracy Jr. Release year: 2026'))

    def test_chrome_marker_vetoes_paper_even_if_player_and_number_match(self):
        c=card();c.update(releaseName='Bowman',setName='Base Set')
        self.assertFalse(ocr_agrees(c,[c],'Tyrone Tracy Jr. Chrome #147'))
        c['setName']='Chrome'
        self.assertTrue(ocr_agrees(c,[c],'Tyrone Tracy Jr. Chrome #147'))

    def test_card_scoped_catalog_has_no_release_400_limit_and_preserves_context(self):
        self.resolver.parallels(self.client,card())
        self.client.request.assert_called_once_with('GET','/v1/catalog/cards/'+CARD)
        self.assertFalse(any('/v1/catalog/parallels' in str(c) for c in self.client.request.call_args_list))
        # Another UUID cannot supply variants for this card.
        self.temp.cleanup();self.setUp()
        self.client.request.return_value=dict(card(identifier=OTHER),parallels=[],parallelCount=0)
        self.hints('Tyrone Tracy Jr. #147');result=self.resolve(card())
        self.assertTrue(result['variantUnresolved']);self.assertEqual(result['card']['id'],CARD)

    def test_biography_dates_never_become_serial_tiers(self):
        text='Vorderseite: MIKEY MATTHEWS\nRückseite: BPP-81\nRESUME: Recorded a TD on 11/22/25 and on 9/12.\nScored against Dallas, 9/14.\n201/275'
        self.assertEqual(serials(text),{('201','275')})
        self.assertEqual(serials('Recorded on 11/22/25.'),set())
        self.assertEqual(serials('Born 9/14'),set())
        self.assertEqual(serials('Rückseite: Serial 138/275'),{('138','275')})

    def test_print_year_is_not_the_sports_season(self):
        c=card();self.assertTrue(ocr_agrees(c,[c],'Tyrone Tracy Jr. © 2026 PANINI'))
        self.assertFalse(ocr_agrees(c,[c],'Tyrone Tracy Jr. Set year: 2026'))

    def test_recover_omitted_candidate_by_exact_ocr_number(self):
        c=card('Wrong Player',OTHER);c.update(number='BCP-76')
        correct=card('Alex Perry');correct.update(number='BCP-43',releaseYear='2025')
        self.client.request.return_value=dict(cards=[correct],total_count=1)
        recovered=self.resolver.recover_candidates(self.client,c,'Rückseite: Alex Perry\nBCP-43')
        self.assertEqual(recovered[CARD]['name'],'Alex Perry')
        self.client.request.assert_called_once_with('GET','/v1/catalog/cards',dict(releaseId=RELEASE,number='BCP-43',take=20,skip=0))
        self.client.request.return_value=dict(cards=[dict(correct,releaseId=OTHER)],total_count=1)
        self.assertEqual(self.resolver.recover_candidates(self.client,c,'BCP-43'),{})

    def test_stop_is_not_downgraded_to_unknown(self):
        event=threading.Event();event.set()
        with self.assertRaises(InterruptedError):self.resolver.resolve({},self.job,self.client,event)

    def test_diagnostics_contain_no_photo_or_ocr_text(self):
        self.hints('PRIVATE OCR');self.choices=['unclear'];self.resolve(card(),'Low')
        text=(self.job/'identity-resolution.json').read_text()
        self.assertNotIn('PRIVATE OCR',text);self.assertNotIn('image',text)

    def test_partial_membership_from_card_detail_and_parallel_only_base_veto(self):
        self.hints('Tyrone Tracy Jr. #147')
        correct = dict(id=PARALLEL, name='Rainbow Foil', isPartial=True)
        excluded = dict(id=OTHER, name='Gold Foil', isPartial=True, cards=[OTHER])
        self.client.request.return_value = dict(card(), isParallelOnly=True, parallels=[correct, excluded], parallelCount=2)
        self.choices = [PARALLEL]
        result = self.resolve(dict(card(), parallelSuggestions=[dict(correct, confidence="Low")]))
        self.assertEqual([p['questions'][0]['name'] for p in self.calls], ['parallel'])
        self.assertEqual({c['value'] for c in self.calls[0]['questions'][0]['choices']}, {PARALLEL, 'unclear'})
        self.assertEqual(result['card']['parallelSuggestions'][0]['cards'], [CARD])
        self.assertTrue(result['card']['isParallelOnly'])
        self.assertEqual(result['eligibleParallels'], [dict(id=PARALLEL, name='Rainbow Foil', numberedTo=None)])
        lookup = CardLookup(self.root, self.client, resolver=self.resolver)
        try:
            analysis = lookup.result(result, [], self.job)['analysis']
            self.assertTrue(analysis['identityConfirmed'])
            self.assertEqual(analysis['cardSightIdentity']['parallelID'], PARALLEL)
        finally:
            lookup.executor.shutdown()

    def test_unreadable_or_missing_finish_keeps_verified_options(self):
        self.hints('Tyrone Tracy Jr. #147')
        self.client.request.return_value = dict(card(), parallels=[dict(id=PARALLEL, name='Rainbow', isPartial=True)], parallelCount=1)
        self.choices = ['unclear']
        result = self.resolve(dict(card(), parallelSuggestions=[dict(id=PARALLEL, confidence='Low')]))
        self.assertTrue(result['variantUnresolved'])
        self.assertEqual({p['id'] for p in result['eligibleParallels']}, {'base', PARALLEL})
        self.assertFalse(result['card'].get('parallelSuggestions'))
        self.assertNotIn('error', json.loads((self.job/'identity-resolution.json').read_text()))

    def test_high_numbered_suggestion_keeps_tier_without_inventing_serial(self):
        candidate = dict(card(), parallelSuggestions=[dict(id=PARALLEL, name="Yellow Wave", confidence="High", numberedTo=275)])
        self.hints("Tyrone Tracy Jr. #147")
        result = self.resolve(candidate)
        self.assertEqual(result["card"]["parallelSuggestions"][0]["numberedTo"], 275)
        self.assertNotIn("observedSerial", result)
        self.assertEqual(self.calls, [])
        self.client.request.assert_not_called()

    def test_parallel_only_or_serial_conflict_blocks_default_without_model(self):
        self.hints("Tyrone Tracy Jr. #147")
        result = self.resolve(dict(card(), isParallelOnly=True))
        self.assertTrue(result["variantUnresolved"])
        self.hints("Tyrone Tracy Jr. #147 22/275")
        self.assertTrue(self.resolve(card())["variantUnresolved"])
        self.assertEqual(self.calls, [])

    def test_weak_suggestions_only_offer_base_and_matching_ids_once(self):
        self.hints("Tyrone Tracy Jr. #147")
        self.client.request.return_value = dict(card(), parallelCount=2, parallels=[
            dict(id=OTHER, name="Gold"), dict(id=PARALLEL, name="Rainbow")])
        c = dict(card(), parallelSuggestions=[dict(id=PARALLEL, confidence="Low")])
        lookup = CardLookup(self.root, self.client, resolver=self.resolver)
        self.addCleanup(lookup.executor.shutdown)
        for answer in ("base", PARALLEL, "unclear"):
            self.choices = [answer]
            self.calls.clear()
            result = lookup.result(self.resolve(c), [], self.job)["analysis"]
            self.assertEqual(result["identityConfirmed"], answer != "unclear")
            self.assertEqual(result["cardSightIdentity"]["parallelID"], PARALLEL if answer == PARALLEL else None)
            self.assertEqual(len(self.calls), 1)
            q = self.calls[0]["questions"][0]
            self.assertEqual(q["name"], "parallel")
            choices = {v["value"]: v for v in q["choices"]}
            self.assertEqual(set(choices), {"base", PARALLEL, "unclear"})
            self.assertEqual(json.loads(choices[PARALLEL]["description"])["confidence"], "Low")

    def test_two_highs_require_one_check(self):
        self.hints("Tyrone Tracy Jr. #147")
        rows = [dict(id=OTHER, name="Gold"), dict(id=PARALLEL, name="Rainbow")]
        self.client.request.return_value = dict(card(), parallels=rows, parallelCount=2)
        self.choices = [OTHER]
        c = dict(card(), parallelSuggestions=[dict(row, confidence="High") for row in rows])
        self.assertEqual(self.resolve(c)["card"]["parallelSuggestions"][0]["id"], OTHER)
        self.assertEqual([p["questions"][0]["name"] for p in self.calls], ["parallel"])

    def test_high_partial_uses_scoped_metadata_without_model(self):
        self.hints("Tyrone Tracy Jr. #147")
        row = dict(id=PARALLEL, name="Rainbow", isPartial=True)
        self.client.request.return_value = dict(card(), parallels=[row], parallelCount=1)
        c = dict(card(), parallelSuggestions=[dict(row, confidence="High")])
        self.assertEqual(self.resolve(c)["card"]["parallelSuggestions"][0]["cards"], [CARD])
        c["parallelSuggestions"][0]["cards"] = [OTHER]
        self.assertTrue(self.resolve(c)["variantUnresolved"])
        self.assertEqual(self.calls, [])

    def test_intrinsically_numbered_standard_card_keeps_its_tier(self):
        self.hints('Tyrone Tracy Jr. #147 12/25')
        self.client.request.return_value = dict(card(), numberedTo=25, parallelCount=0, parallels=[])
        resolved = self.resolve(card())
        self.assertEqual(resolved['card']['parallelSuggestions'], [])
        self.assertEqual(resolved['card']['numberedTo'], 25)
        self.assertEqual(resolved['observedSerial'], '12/25')

    def test_slab_is_preserved_through_confirmed_and_partial_price_gates(self):
        self.hints('Tyrone Tracy Jr. #147')
        grading = dict(company={'name': 'PSA'})
        c = card()
        self.client.request.return_value = dict(card(), parallelCount=0, parallels=[])
        lookup = CardLookup(self.root, self.client, resolver=self.resolver)
        try:
            for parallel_only in (False, True):
                c['isParallelOnly'] = parallel_only
                d = self.resolver.resolve(dict(confidence='High', zIndex=0, card=c, grading=grading), self.job, self.client)
                a = lookup.result(d, [], self.job)['analysis']
                self.assertEqual(a['identityConfirmed'], not parallel_only)
                self.assertTrue(a['cardSightIdentity']['slabbed'])
                self.assertIsNone(lookup.key(a))
        finally:
            lookup.executor.shutdown()

    def test_partial_set_recovery_is_scoped_and_image_checked(self):
        c = card()
        c.update(number='GN-16', setName='Gen Next')
        partial = {k: c[k] for k in ('setId', 'releaseId', 'year', 'manufacturer', 'releaseName', 'setName')}
        self.hints('Tyrone Tracy Jr.\nRückseite: GN-16')
        self.client.request.side_effect = [dict(cards=[dict(c, releaseYear='2025')], total_count=1),
                                           dict(c, parallelCount=0, parallels=[])]
        self.choices = [CARD]
        result = self.resolve(partial)
        self.assertEqual(self.client.request.call_args_list[0].args[2], dict(setId=SET, releaseId=RELEASE, number='GN-16', take=20, skip=0))
        self.assertEqual([p['questions'][0]['name'] for p in self.calls], ['card'])
        self.assertEqual(result['card']['id'], CARD)

    def test_missing_detection_recovers_only_supported_football_release(self):
        c = card('Mason Heintschel')
        c.update(number='BCP-131', releaseName='Bowman', setName='Chrome Prospects', year='2026', releaseYear='2026',
                 releaseId='77793c3e-ecba-4028-aa75-bab377c4ac97', manufacturer='Topps')
        text = 'Vorderseite: MASON HEINTSCHEL\nBowman\nRückseite: MASON HEINTSCHEL\nBCP-131\n© Topps'
        self.hints(text)
        self.client.request.side_effect = [dict(cards=[dict(c, releaseId=OTHER)], total_count=1),
                                           dict(cards=[c], total_count=1), dict(c, parallelCount=0, parallels=[])]
        self.assertEqual(self.resolver.resolve({'noDetection': True}, self.job, self.client), {})
        self.assertFalse(self.calls)
        self.choices = [CARD, 'base']
        result = self.resolver.resolve({'noDetection': True}, self.job, self.client)
        self.assertEqual(self.client.request.call_args_list[1].args[2]['name'], 'mason heintschel')
        self.assertEqual(result['card']['id'], CARD)
        self.assertEqual(self.resolver.resolve({}, self.job, self.client), {})
        self.assertEqual(self.client.request.call_count, 3)

    def test_local_ocr_normalization_preserves_jersey_and_bio_boundaries(self):
        fields = ocr_fields('Vorderseite: Brock\nRückseite: 87\nUP CLOSE: Wears #13 in homage to his childhood hero.')
        self.assertEqual(fields['numbers'], set())
        self.assertEqual(fields['backNumber'], '87')
        for raw, expected in [('ВСP-143', 'BCP-143'), ('BPP 66', 'BPP-66')]:
            self.assertEqual(ocr_fields('Rückseite: '+raw)['queries'], {expected})

    def test_name_only_high_requires_visual_confirmation(self):
        self.hints('Tyrone Tracy Jr.')
        self.choices = ['unclear']
        self.assertEqual(self.resolve(card()), {})
        self.assertEqual([p['questions'][0]['name'] for p in self.calls], ['card'])

    def test_temporary_error_is_distinguished_from_genuine_uncertainty(self):
        self.hints('Tyrone Tracy Jr. #147')
        self.client.request.side_effect = TimeoutError()
        result = self.resolve(card())
        self.assertTrue(result['variantUnresolved'])
        self.assertIn('error', json.loads((self.job/'identity-resolution.json').read_text()))

    def test_missing_or_contradictory_metadata_cannot_offer_base(self):
        self.hints('Tyrone Tracy Jr. #147 4/99')
        self.client.request.return_value = dict(card(), parallels=[
            dict(id=PARALLEL, name='Gold', setId=OTHER, isPartial=True, numberedTo=99)], parallelCount=1)
        partial = self.resolve(card())
        self.assertTrue(partial['variantUnresolved'])
        self.assertEqual(partial['eligibleParallels'], [])
        self.assertEqual(partial['observedSerial'], '4/99')
        self.assertIn('error', json.loads((self.job/'identity-resolution.json').read_text()))

    def test_conflicting_card_fields_for_same_id_are_not_accepted(self):
        c = card()
        c['suggestions'] = [dict(c, number='148')]
        self.hints('Tyrone Tracy Jr. #147')
        self.assertEqual(self.resolve(c), {})
        self.assertFalse(self.calls)

    def test_competing_numeric_back_position_cannot_take_fast_path(self):
        c = card()
        self.hints('Vorderseite: Tyrone Tracy Jr.\nDonruss Optic\nRückseite: 148')
        self.client.request.return_value = dict(cards=[], total_count=0)
        self.choices = ['unclear']
        self.assertEqual(self.resolve(c), {})
        self.assertEqual(self.client.request.call_args.args[2]['number'], '148')
        self.assertEqual(self.calls, [])

    def test_flagship_unclear_identity_triggers_one_focused_back_read(self):
        import edition_review
        release = edition_review.FLAGSHIP
        c = dict(card(), releaseId=release, year="2026", releaseYear="2026", manufacturer="Topps",
                 releaseName="Topps Flagship Football", setName="1991 Topps", number="91TF-35")
        (self.job / "back.jpg").write_bytes(b"fixture back")
        (self.root / "config.json").write_text(json.dumps(dict(apiEnabled=True, apiModel="fixture")))
        self.hints("Front: TYRONE TRACY JR.\nBack: Produced by The Topps Company")
        self.choices = ["unclear", "base"]
        self.client.request.side_effect = [dict(cards=[c], total_count=1), dict(c, parallels=[], parallelCount=0)]
        fields = dict(player=c["name"], number=c["number"], release=c["releaseName"])
        with patch("api_client.run_response", return_value=fields) as back_read:
            result = self.resolve(c, "Medium")
        back_read.assert_called_once()
        self.assertEqual(result["card"]["id"], CARD)
        self.assertEqual(result["finishState"], "verified")
        self.assertEqual(self.client.request.call_args_list[0].args[2]["number"], "91TF-35")
        self.assertEqual([p["questions"][0]["name"] for p in self.calls], ["card", "catalog_finish"])

    def test_other_release_retries_with_all_eligible_options_after_unclear_suggestion(self):
        (self.job / "back.jpg").write_bytes(b"fixture back")
        self.hints("Front: Tyrone Tracy Jr.\nBack: Card number 147")
        self.client.request.return_value = dict(card(), parallelCount=2, parallels=[
            dict(id=OTHER, name="Gold"), dict(id=PARALLEL, name="Rainbow")])
        c = dict(card(), parallelSuggestions=[dict(id=PARALLEL, confidence="Low")])
        self.choices = ["unclear", OTHER]
        result = self.resolve(c)
        self.assertEqual(result["card"]["parallelSuggestions"][0]["id"], OTHER)
        questions = [p["questions"][0] for p in self.calls]
        self.assertEqual([q["name"] for q in questions], ["parallel", "catalog_retry"])
        self.assertNotIn(OTHER, {c["value"] for c in questions[0]["choices"]})
        self.assertIn(OTHER, {c["value"] for c in questions[1]["choices"]})
